import Foundation

private actor AutomationStreamAccumulator {
  private var text = ""
  func append(_ delta: String) { text += delta }
  func value() -> String { text }
}

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
      if normalized.nextRun <= .now { normalized.nextRun = normalized.nextDate(after: .now) }
      if let index = candidate.items.firstIndex(where: { $0.id == item.id }) {
        candidate.items[index] = normalized
      } else {
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
    automationRunningIDs.insert(id)
    defer { automationRunningIDs.remove(id) }
    do {
      let config = modelConfiguration
      _ = try config.endpoint("chat/completions")
      guard !config.model.isEmpty else { throw AgentFailure(message: "请先在设置 → 模型与 API 配置独立服务。") }
      guard personalizationLoaded, memoryError == nil else {
        throw AgentFailure(message: "个人指令或记忆尚未成功加载。")
      }
      let key = try ModelKeychain.read(account: config.credentialAccount)
      let pluginContext = try PluginStorage.promptContext(
        prompt: item.prompt, preferences: activePluginPreferences, root: dataRoot)
      let instructions = [systemInstructions, pluginContext.instructions]
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
      let messages = [
        ChatMessage(role: "system", content: instructions),
        ChatMessage(role: "user", content: item.prompt),
      ]
      let now = Date().timeIntervalSince1970 * 1000
      var metadata: [String: JSONValue] = [
        "kind": .string("chat"), "model": .string(config.model),
        "automation_id": .string(item.id.uuidString),
      ]
      if !pluginContext.ids.isEmpty { metadata["plugins"] = .array(pluginContext.ids.map(JSONValue.string)) }
      if !pluginContext.skillIDs.isEmpty {
        metadata["skills"] = .array(pluginContext.skillIDs.map(JSONValue.string))
      }
      var run = AgentRun(
        id: UUID().uuidString, kind: "chat", project: item.project, status: "running",
        createdAt: now, updatedAt: now, request: .object(metadata),
        result: .object(["response": .string("")]))
      var candidate = library
      candidate.attach(run, to: item.taskID, note: item.prompt)
      candidate.chatRuns.append(run)
      let ownerID = candidate.task(containing: run.id)?.id
      try commitLibrary(candidate)
      if item.project == currentProjectKey { runs.insert(run, at: 0) }

      let accumulator = AutomationStreamAccumulator()
      do {
        let usage = try await ModelAPIClient().stream(
          config: config, key: key, messages: messages, attachmentRoot: dataRoot
        ) { delta in await accumulator.append(delta) }
        let response = await accumulator.value()
        var result: [String: JSONValue] = ["response": .string(response)]
        if let usage { result["usage"] = usage.jsonValue }
        run = AgentRun(
          id: run.id, kind: run.kind, project: run.project, status: "succeeded",
          createdAt: run.createdAt, updatedAt: Date().timeIntervalSince1970 * 1000,
          request: run.request, result: .object(result))
      } catch {
        let response = await accumulator.value()
        run = AgentRun(
          id: run.id, kind: run.kind, project: run.project, status: "failed",
          createdAt: run.createdAt, updatedAt: Date().timeIntervalSince1970 * 1000,
          request: run.request,
          result: .object(["response": .string(response), "message": .string(error.localizedDescription)]))
      }
      if let index = library.chatRuns.firstIndex(where: { $0.id == run.id }) { library.chatRuns[index] = run }
      if let index = runs.firstIndex(where: { $0.id == run.id }) { runs[index] = run }
      saveLibrary()
      guard var updated = automationPreferences.items.first(where: { $0.id == id }) else { return }
      updated.lastRun = scheduledAt
      updated.lastRunID = run.id
      updated.taskID = ownerID
      updated.nextRun = updated.nextDate(after: max(scheduledAt, .now))
      _ = saveAutomation(updated)
      if let taskID = ownerID { library.unreadTasks.insert(taskID); saveLibrary() }
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
