import Foundation

extension WorkspaceStore {
  func loadAutomations() async {
    guard !automationsLoading else { return }
    automationsLoading = true
    defer { automationsLoading = false }
    let root = dataRoot
    do {
      automationPreferences = try await Task.detached(priority: .userInitiated) {
        try AutomationStorage.load(root: root)
      }.value
      automationsLoaded = true
      automationsError = nil
    } catch {
      automationsError = "无法读取自动化：\(error.localizedDescription)"
    }
  }

  @discardableResult func saveAutomation(_ item: ShipAutomation) -> Bool {
    guard automationsLoaded else { return false }
    do {
      var candidate = automationPreferences
      var normalized = item
      normalized.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
      normalized.prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      if let index = candidate.items.firstIndex(where: { $0.id == item.id }) {
        candidate.items[index] = normalized
      } else {
        if normalized.nextRun <= .now { normalized.nextRun = normalized.nextDate(after: .now) }
        candidate.items.insert(normalized, at: 0)
      }
      try AutomationStorage.save(candidate, root: dataRoot)
      automationPreferences = candidate
      automationsError = nil
      return true
    } catch {
      automationsError = error.localizedDescription
      return false
    }
  }

  func setAutomationEnabled(_ enabled: Bool, id: UUID) {
    guard var item = automationPreferences.items.first(where: { $0.id == id }) else { return }
    item.enabled = enabled
    if enabled { item.nextRun = item.nextDate(after: .now) }
    _ = saveAutomation(item)
  }

  func deleteAutomation(_ id: UUID) {
    do {
      var candidate = automationPreferences
      candidate.items.removeAll { $0.id == id }
      try AutomationStorage.save(candidate, root: dataRoot)
      automationPreferences = candidate
      automationsError = nil
    } catch { automationsError = error.localizedDescription }
  }

  func markAutomationReviewed(_ id: UUID) {
    guard var item = automationPreferences.items.first(where: { $0.id == id }) else { return }
    item.reviewedRunID = item.lastRunID
    _ = saveAutomation(item)
  }

  func openAutomationResult(_ id: UUID) {
    guard let item = automationPreferences.items.first(where: { $0.id == id }),
      let taskID = item.taskID,
      let task = library.tasks.first(where: { $0.id == taskID })
    else { return }
    markAutomationReviewed(id)
    selectTask(task)
  }

  func runDueAutomations(now: Date = .now) async {
    guard automationsLoaded, !shuttingDown else { return }
    let due = automationPreferences.items.filter {
      $0.enabled && $0.nextRun <= now && !automationRunningIDs.contains($0.id)
    }.map(\.id)
    for id in due { await runAutomation(id, scheduledAt: now) }
  }

  func runAutomation(_ id: UUID, scheduledAt: Date = .now) async {
    guard let item = automationPreferences.items.first(where: { $0.id == id }),
      !automationRunningIDs.contains(id)
    else { return }
    // A temporary workspace transition must not consume the scheduled occurrence.
    guard !busy, !managedTaskPreparing, !shuttingDown,
      !handoffBlocksProject(item.project) else { return }
    if let taskID = item.taskID, activeRun(taskID: taskID) != nil { return }
    automationRunningIDs.insert(id)
    defer { automationRunningIDs.remove(id) }
    do {
      guard libraryLoaded else { throw AgentFailure(message: "工作区尚未加载完成。") }
      let existingTask = item.taskID.flatMap { taskID in
        library.tasks.first(where: { $0.id == taskID && $0.project == item.project })
      }
      let ownerID = existingTask?.id ?? UUID().uuidString
      if existingTask == nil {
        var candidate = library
        candidate.tasks.insert(WorkspaceTask(
          id: ownerID, project: item.project, title: item.name, runIDs: []), at: 0)
        try commitLibrary(candidate)
      }
      guard let runID = await startChat(item.prompt, taskID: ownerID, automationID: id) else {
        if existingTask == nil {
          var candidate = library
          candidate.tasks.removeAll { $0.id == ownerID && $0.runIDs.isEmpty }
          try commitLibrary(candidate)
        }
        throw AgentFailure(message: error ?? "自动化当前无法启动，请稍后重试。")
      }
      if var running = automationPreferences.items.first(where: { $0.id == id }) {
        running.taskID = ownerID
        _ = saveAutomation(running)
      }
      await modelTask(runID: runID)?.value
      guard let run = library.chatRuns.first(where: { $0.id == runID }), !run.isActive else {
        throw AgentFailure(message: "自动化运行尚未完成。")
      }
      guard var updated = automationPreferences.items.first(where: { $0.id == id }) else { return }
      updated.lastRun = scheduledAt
      updated.lastRunID = runID
      updated.taskID = ownerID
      updated.nextRun = updated.nextDate(after: max(scheduledAt, .now))
      _ = saveAutomation(updated)
      library.unreadTasks.insert(ownerID)
      saveLibrary()
    } catch {
      automationsError = error.localizedDescription
      if var failed = automationPreferences.items.first(where: { $0.id == id }) {
        failed.nextRun = failed.nextDate(after: max(scheduledAt, .now))
        _ = saveAutomation(failed)
        automationsError = error.localizedDescription
      }
    }
  }
}
