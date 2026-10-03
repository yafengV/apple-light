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
      normalized.modelID = item.modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
      if normalized.modelID?.isEmpty == true { normalized.modelID = nil }
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

  @discardableResult func saveEditedAutomation(_ item: ShipAutomation) -> Bool {
    var edited = item
    if let previous = automationPreferences.items.first(where: { $0.id == item.id }) {
      // The editor may have opened before a run completed. Keep runtime state from storage.
      edited.lastRun = previous.lastRun
      edited.taskID = previous.taskID
      edited.lastRunID = previous.lastRunID
      edited.reviewedRunID = previous.reviewedRunID
      edited.pendingRunIDs = previous.pendingRunIDs
      edited.preparingTaskIDs = previous.preparingTaskIDs
      edited.activeOccurrenceAt = previous.activeOccurrenceAt
      edited.completedProjectsForOccurrence = previous.completedProjectsForOccurrence
      edited.completedAt = previous.completedAt
      let scheduleChanged = previous.cadence != item.cadence || previous.hour != item.hour
        || previous.minute != item.minute || previous.selectedWeekdays != item.selectedWeekdays
        || previous.customRule != item.customRule
      if scheduleChanged || !previous.enabled && item.enabled {
        if (scheduleChanged || previous.completedAt != nil) && item.cadence == .custom {
          edited.scheduleAnchor = .now
        }
        edited.completedAt = nil
        if let next = edited.nextScheduledDate(after: .now) { edited.nextRun = next }
      } else {
        edited.nextRun = previous.nextRun
      }
    } else {
      if item.cadence == .custom { edited.scheduleAnchor = .now }
      if let next = edited.nextScheduledDate(after: .now) { edited.nextRun = next }
    }
    return saveAutomation(edited)
  }

  func setAutomationEnabled(_ enabled: Bool, id: UUID) {
    guard var item = automationPreferences.items.first(where: { $0.id == id }) else { return }
    item.enabled = enabled
    if enabled {
      if item.completedAt != nil && item.cadence == .custom { item.scheduleAnchor = .now }
      item.completedAt = nil
      guard let next = item.nextScheduledDate(after: .now) else { return }
      item.nextRun = next
    }
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
    guard let item = automationPreferences.items.first(where: { $0.id == id }) else { return }
    guard let runID = item.unresolvedRunIDs.first else { return }
    markAutomationReviewed(id, runID: runID)
  }

  func markAutomationReviewed(_ id: UUID, runID: String) {
    guard var item = automationPreferences.items.first(where: { $0.id == id }),
      item.unresolvedRunIDs.contains(runID) else { return }
    item.pendingRunIDs = item.unresolvedRunIDs.filter { $0 != runID }
    if item.lastRunID == runID { item.reviewedRunID = runID }
    _ = saveAutomation(item)
  }

  func markAllAutomationsReviewed() {
    guard automationsLoaded, libraryLoaded else { return }
    var candidate = automationPreferences
    let pending = Set(candidate.items.flatMap(\.unresolvedRunIDs))
    guard !pending.isEmpty else { return }
    for index in candidate.items.indices where candidate.items[index].needsReview {
      candidate.items[index].pendingRunIDs = []
      candidate.items[index].reviewedRunID = candidate.items[index].lastRunID
    }
    var updatedLibrary = library
    let taskIDs = updatedLibrary.tasks.filter { task in
      task.runIDs.contains(where: pending.contains)
    }.map(\.id)
    updatedLibrary.unreadTasks.subtract(taskIDs)
    do {
      try AutomationStorage.save(candidate, root: dataRoot)
      do { try commitLibrary(updatedLibrary) }
      catch {
        try? AutomationStorage.save(automationPreferences, root: dataRoot)
        throw error
      }
      automationPreferences = candidate
      automationsError = nil
    } catch { automationsError = "无法标记自动化结果为已读：\(error.localizedDescription)" }
  }

  func openAutomationResult(_ id: UUID) {
    guard let item = automationPreferences.items.first(where: { $0.id == id }),
      let runID = item.unresolvedRunIDs.first ?? item.lastRunID else { return }
    openAutomationRun(runID, automationID: id)
  }

  func openAutomationRun(_ runID: String, automationID: UUID) {
    guard library.chatRuns.contains(where: {
      $0.id == runID && $0.request["automation_id"].text == automationID.uuidString
    }), let task = library.task(containing: runID), canSelectTask(task) else { return }
    if currentProjectKey == task.project {
      selectTask(task)
      if selectedTask?.id == task.id { markAutomationReviewed(automationID, runID: runID) }
    } else {
      Task {
        if await selectTaskAwaitingScope(task) { markAutomationReviewed(automationID, runID: runID) }
      }
    }
  }

  func openAutomationCurrentTask(_ id: UUID) {
    guard let taskID = automationPreferences.items.first(where: { $0.id == id })?.taskID,
      let task = library.tasks.first(where: { $0.id == taskID }) else { return }
    selectTask(task)
  }

  func runDueAutomations(now: Date = .now) async {
    guard automationsLoaded, !shuttingDown else { return }
    let due = automationPreferences.items.filter {
      $0.enabled && $0.nextRun <= now && !automationRunningIDs.contains($0.id)
    }.map(\.id)
    for id in due { await runAutomation(id, scheduledAt: now) }
  }

  func runAutomation(_ id: UUID, scheduledAt: Date = .now,
    readWatchedPullRequest: @escaping @Sendable (GitHubPullRequest, URL) async throws -> GitHubPRDetails = {
      try await GitHubPRService().details(for: $0, at: $1)
    }) async {
    guard let item = automationPreferences.items.first(where: {
      $0.id == id && ($0.enabled || $0.watchedPullRequest == nil)
    }),
      !automationRunningIDs.contains(id)
    else { return }
    // A temporary workspace transition must not consume the scheduled occurrence.
    guard !busy, !managedTaskPreparing, !shuttingDown,
      !item.selectedProjects.contains(where: handoffBlocksProject) else { return }
    guard validatePullRequestWatchTarget(item) else { return }
    if let taskID = item.taskID, activeRun(taskID: taskID) != nil { return }
    automationRunningIDs.insert(id)
    defer { automationRunningIDs.remove(id) }
    if let watched = item.watchedPullRequest, item.activeOccurrenceAt == nil {
      do {
        let fresh = try await readWatchedPullRequest(watched, URL(fileURLWithPath: item.project))
        guard let current = automationPreferences.items.first(where: { $0.id == id }),
          current.enabled, current.watchedPullRequest?.validatedURL == watched.validatedURL else { return }
        guard fresh.number == watched.number, fresh.url == watched.validatedURL?.absoluteString else {
          throw GitHubPRRefreshRequired(message: "PR 身份已改变，监控未运行。")
        }
        let green = fresh.mergeable?.uppercased() == "MERGEABLE"
          && fresh.checkSummary.failed == 0 && fresh.checkSummary.pending == 0
          && fresh.statusCheckRollup != nil && !fresh.isDraft
        let shouldStop = fresh.state.uppercased() != "OPEN"
          || green && !library.gitPreferences.autoMergeWatchedPullRequests
            && library.gitPreferences.pullRequestWatchInstructions
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if shouldStop {
          var completed = current
          completed.enabled = false
          completed.completedAt = scheduledAt
          completed.watchedPullRequest = fresh.recorded(updating: watched)
          _ = saveAutomation(completed)
          return
        }
        let currentRequest = fresh.recorded(updating: watched)
        if let prompt = PullRequestWatchPrompt.make(currentRequest,
          preferences: library.gitPreferences) {
          var refreshed = current
          refreshed.prompt = prompt
          refreshed.watchedPullRequest = currentRequest
          guard saveAutomation(refreshed) else { return }
        }
      } catch {
        if var delayed = automationPreferences.items.first(where: { $0.id == id }) {
          delayed.nextRun = scheduledAt.addingTimeInterval(300)
          _ = saveAutomation(delayed)
        }
        automationsError = "PR 监控无法核对当前状态，将稍后重试：\(error.localizedDescription)"
        return
      }
    }
    // The PR preflight can refresh the prompt or pause the watch. Use that saved state
    // for activation and for the message sent to the retained conversation.
    guard let item = automationPreferences.items.first(where: {
      $0.id == id && ($0.enabled || $0.watchedPullRequest == nil)
    }) else { return }
    guard validatePullRequestWatchTarget(item) else { return }
    let occurrence = item.activeOccurrenceAt ?? scheduledAt
    if item.activeOccurrenceAt == nil {
      var activated = item
      activated.activeOccurrenceAt = occurrence
      activated.completedProjectsForOccurrence = []
      guard saveAutomation(activated) else { return }
    }
    var failures: [String] = []
    for project in item.selectedProjects {
      guard var state = automationPreferences.items.first(where: { $0.id == id }) else { break }
      if state.completedProjectsForOccurrence?.contains(project) == true { continue }
      let ownerID = state.preparingTaskIDs?[project]
        ?? (state.watchedPullRequest != nil ? state.taskID : nil)
        ?? UUID().uuidString
      if state.preparingTaskIDs?[project] == nil {
        state.preparingTaskIDs = state.preparingTaskIDs ?? [:]
        state.preparingTaskIDs?[project] = ownerID
        guard saveAutomation(state) else { return }
      }
      do {
        guard libraryLoaded else { throw AgentFailure(message: "工作区尚未加载完成。") }
        // Recovery belongs to its recorded task, even if project defaults have since changed.
        if let existingRunID = library.tasks.first(where: { $0.id == ownerID })?.runIDs.last,
          (state.watchedPullRequest == nil || existingRunID != state.lastRunID),
          let existingRun = library.chatRuns.first(where: { $0.id == existingRunID }) {
          if existingRun.request["automation_id"].text != id.uuidString,
            state.watchedPullRequest == nil {
            throw AgentFailure(message: "待恢复任务不属于此自动化，未重复执行。")
          }
          if existingRun.request["automation_id"].text == id.uuidString {
            if existingRun.isActive { await modelTask(runID: existingRunID)?.value }
            guard library.chatRuns.first(where: { $0.id == existingRunID })?.isActive == false else {
              throw AgentFailure(message: "上次自动化运行仍未结束。")
            }
            try recordAutomationProjectResult(id: id, project: project,
              taskID: ownerID, runID: existingRunID)
            continue
          }
        }
        let existingTask = library.tasks.first(where: { $0.id == ownerID })
        let sourcePath = library.managedWorktree(forTaskID: ownerID)?.source
          ?? existingTask?.project ?? library.primaryFolder(for: project)
        let source = URL(fileURLWithPath: sourcePath)
        let useWorktree = state.selectedExecution == .worktree && !project.isEmpty
          && FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path)
        if state.watchedPullRequest != nil && !useWorktree {
          throw AgentFailure(message: "PR 监控需要 Git 仓库及隔离工作树，未在当前检出目录运行。")
        }
        let record = useWorktree
          ? try await prepareAutomationWorktree(sourcePath: sourcePath, taskID: ownerID,
            environmentSelection: state.environmentSelection(for: project),
            includeSourceChanges: state.watchedPullRequest == nil) : nil
        if state.watchedPullRequest != nil {
          guard let current = automationPreferences.items.first(where: { $0.id == id && $0.enabled }),
            validatePullRequestWatchTarget(current) else { return }
        }
        let runProject = record?.path ?? sourcePath
        var candidate = library
        if let index = candidate.tasks.firstIndex(where: { $0.id == ownerID }) {
          candidate.tasks[index].project = runProject
          if candidate.tasks[index].runIDs.isEmpty,
            candidate.tasks[index].modelSelection == nil {
            candidate.tasks[index].modelSelection = automationModelSelection(state)
          }
        } else {
          var task = WorkspaceTask(id: ownerID, project: runProject, title: item.name, runIDs: [])
          task.modelSelection = automationModelSelection(state)
          candidate.tasks.insert(task, at: 0)
        }
        if let record {
          var profile = candidate.profiles[sourcePath] ?? BuildProfile()
          record.environment?.apply(to: &profile)
          candidate.profiles[runProject] = profile
        }
        try commitLibrary(candidate)
        guard let runID = await startChat(item.prompt, taskID: ownerID, automationID: id) else {
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
        try recordAutomationProjectResult(id: id, project: project,
          taskID: ownerID, runID: runID)
      } catch {
        let title = project.isEmpty ? "无项目" : library.projectTitle(project)
        failures.append("\(title)：\(error.localizedDescription)")
        let latestRunID = library.tasks.first(where: { $0.id == ownerID })?.runIDs.last
        let hasUnrecordedRun = latestRunID != state.lastRunID
          && library.chatRuns.contains {
            $0.id == latestRunID && $0.request["automation_id"].text == id.uuidString
          }
        if !hasUnrecordedRun, var failed = automationPreferences.items.first(where: { $0.id == id }) {
          if !library.managedWorktrees.contains(where: { $0.taskID == ownerID }) {
            if failed.watchedPullRequest == nil {
              var candidate = library
              candidate.tasks.removeAll { $0.id == ownerID && $0.runIDs.isEmpty }
              try? commitLibrary(candidate)
            }
            failed.preparingTaskIDs?[project] = nil
          }
          failed.completedProjectsForOccurrence = (failed.completedProjectsForOccurrence ?? []) + [project]
          _ = saveAutomation(failed)
        }
      }
    }
    if var updated = automationPreferences.items.first(where: { $0.id == id }) {
      if Set(updated.selectedProjects).isSubset(of: Set(updated.completedProjectsForOccurrence ?? [])) {
        updated.lastRun = occurrence
        if let next = updated.nextScheduledDate(after: max(occurrence, .now)) {
          updated.nextRun = next
        } else {
          updated.enabled = false
          updated.completedAt = occurrence
        }
        updated.activeOccurrenceAt = nil
        updated.completedProjectsForOccurrence = nil
        _ = saveAutomation(updated)
      }
    }
    if !failures.isEmpty { automationsError = failures.joined(separator: "\n") }
  }

  private func recordAutomationProjectResult(id: UUID, project: String,
    taskID: String, runID: String) throws {
    guard var updated = automationPreferences.items.first(where: { $0.id == id }) else {
      throw AgentFailure(message: "自动化记录已删除。")
    }
    if !updated.unresolvedRunIDs.contains(runID) {
      updated.pendingRunIDs = updated.unresolvedRunIDs + [runID]
    }
    updated.lastRunID = runID
    updated.taskID = taskID
    if updated.completedProjectsForOccurrence?.contains(project) != true {
      updated.completedProjectsForOccurrence = (updated.completedProjectsForOccurrence ?? []) + [project]
    }
    updated.preparingTaskIDs?[project] = nil
    guard saveAutomation(updated) else {
      throw AgentFailure(message: automationsError ?? "无法保存自动化运行结果。")
    }
    library.unreadTasks.insert(taskID)
    saveLibrary()
  }

  private func automationModelSelection(_ item: ShipAutomation) -> TaskModelSelection? {
    guard item.modelID != nil || item.reasoning != nil else { return nil }
    return TaskModelSelection(model: item.modelID ?? modelConfiguration.model,
      reasoning: item.reasoning ?? modelConfiguration.reasoning,
      providerAccount: modelConfiguration.credentialAccount,
      apiProtocol: modelConfiguration.apiProtocol)
  }
}
