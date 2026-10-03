import Foundation

extension WorkspaceStore {
  func pausableWatch(runID: String) -> ShipAutomation? {
    guard libraryLoaded, automationsLoaded, !shuttingDown,
      let run = library.chatRuns.first(where: { $0.id == runID }), run.isActive,
      let raw = run.request["automation_id"].text, let id = UUID(uuidString: raw),
      let task = library.task(containing: runID), !task.archived, !task.isTransient else { return nil }
    return automationPreferences.items.first {
      $0.id == id && $0.taskID == task.id && $0.watchedPullRequest?.validatedURL != nil
    }
  }

  /// Persist before acknowledging. A model can never pause another task's schedule.
  func pauseWatchedAutomation(runID: String, reason: String) throws -> ShipAutomation {
    guard var watch = pausableWatch(runID: runID) else {
      throw AgentFailure(message: "此回合没有关联的有效 PR 监控。")
    }
    let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty, reason.utf8.count <= 4096, !reason.utf8.contains(0) else {
      throw AgentFailure(message: "请提供 4096 字节内的具体暂停原因。")
    }
    if watch.enabled {
      watch.enabled = false
      watch.pauseReason = reason
      watch.pausedAt = .now
      guard saveAutomation(watch) else {
        throw AgentFailure(message: automationsError ?? "暂停日程保存失败，不能认为监控已暂停。")
      }
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: "已暂停自动修复", level: .info)
    }
    return watch
  }

  func pauseWatchForBlocker(runID: String, reason: String) {
    guard pausableWatch(runID: runID) != nil else { return }
    do { _ = try pauseWatchedAutomation(runID: runID, reason: String(reason.prefix(1000))) }
    catch {
      notices.show(id: "pr-watch-pause-error:" + runID, title: error.localizedDescription, level: .error)
    }
  }

  func executeAutomationPauseTool(_ call: ModelFunctionCall, runID: String,
    expectedAutomationID: UUID) throws -> String {
    try Task.checkCancellation()
    var execution = MCPToolExecution(callID: call.id, serverID: ModelAutomationPauseTool.serverID,
      serverName: "ShipiOS", toolName: "暂停 PR 监控", arguments: call.arguments, status: .running)
    try saveToolExecution(execution, runID: runID)
    let output: JSONValue
    do {
      guard let watch = pausableWatch(runID: runID), watch.id == expectedAutomationID,
        call.name == ModelAutomationPauseTool.name,
        case .object(let arguments) = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)),
        Set(arguments.keys) == ["reason"], let reason = arguments["reason"]?.text else {
        throw AgentFailure(message: "暂停工具的任务归属或参数无效。")
      }
      let paused = try pauseWatchedAutomation(runID: runID, reason: reason)
      output = .object(["status": .string("paused"), "automation_id": .string(paused.id.uuidString),
        "reason": .string(paused.pauseReason ?? reason), "current_turn_continues": .bool(true)])
      execution.status = .succeeded
    } catch {
      output = .object(["status": .string("error"), "message": .string(error.localizedDescription)])
      execution.status = .failed
    }
    execution.output = output.pretty
    try saveToolExecution(execution, runID: runID)
    return output.pretty
  }

  func handleCodexAutomationPause(runID: String, taskID: String, event: JSONValue) async throws {
    guard library.task(containing: runID)?.id == taskID,
      let id = event["requestId"].text,
      let raw = event["automationId"].text, let automationID = UUID(uuidString: raw) else {
      throw AgentFailure(message: "监控暂停请求缺少有效身份。")
    }
    let args: JSONValue = .object(["reason": event["reason"]])
    let call = ModelFunctionCall(id: id, name: ModelAutomationPauseTool.name, arguments: args.pretty)
    let text = try executeAutomationPauseTool(call, runID: runID, expectedAutomationID: automationID)
    let result = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    try await codexTransport.resolveAutomationRequest(taskID: taskID, requestID: id, result: result)
  }
}
