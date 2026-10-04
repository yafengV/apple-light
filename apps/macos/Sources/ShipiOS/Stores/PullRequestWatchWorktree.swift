import Foundation

extension WorkspaceStore {
  func executeWatchWorktreeTool(_ call: ModelFunctionCall, runID: String,
    expectedAutomationID: UUID) throws -> String {
    try Task.checkCancellation()
    var execution = MCPToolExecution(callID: call.id, serverID: ModelAutomationPauseTool.serverID,
      serverName: "ShipiOS", toolName: "请求 PR 修复工作树", arguments: call.arguments, status: .running)
    try saveToolExecution(execution, runID: runID)
    let output: JSONValue
    do {
      guard let watch = pausableWatch(runID: runID), watch.id == expectedAutomationID, watch.enabled,
        let taskID = watch.taskID, call.name == ModelWatchWorktreeTool.name,
        case .object(let arguments) = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)),
        Set(arguments.keys) == ["reason"], let rawReason = arguments["reason"]?.text else {
        throw AgentFailure(message: "工作树请求的监控归属或参数无效。")
      }
      let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !reason.isEmpty, reason.utf8.count <= 4096, !reason.utf8.contains(0) else {
        throw AgentFailure(message: "请提供 4096 字节内的具体代码修复或冲突解决原因。")
      }
      if let existing = library.managedWorktree(forTaskID: taskID), existing.ready,
        existing.setupCompleted == true,
        library.tasks.first(where: { $0.id == taskID })?.project == existing.path,
        library.chatRuns.first(where: { $0.id == runID })?.project == existing.path {
        output = .object(["status": .string("ready"), "path": .string(existing.path)])
      } else {
        guard let run = library.chatRuns.first(where: { $0.id == runID }),
          run.request["watch_phase"].text == "inspection",
          library.tasks.first(where: { $0.id == taskID })?.project == run.project else {
          throw AgentFailure(message: "只有原检出目录中的 PR 检查回合可以请求修复工作树。")
        }
        // The request is durable before acknowledgement; a failed/cancelled turn must
        // never trigger preparation. Repeated calls preserve the first reason.
        if run.result?["watch_worktree_request"].text == nil {
          try setChatResultField("watch_worktree_request", value: .string(reason), runID: runID)
        }
        output = .object(["status": .string("requested"), "checkout_created": .bool(false),
          "instruction": .string("Finish this read-only turn. ShipiOS will prepare an isolated worktree and continue the same thread there. Do not modify or switch the configured checkout.")])
      }
      execution.status = .succeeded
    } catch {
      output = .object(["status": .string("error"), "message": .string(error.localizedDescription)])
      execution.status = .failed
    }
    execution.output = output.pretty
    try saveToolExecution(execution, runID: runID)
    return output.pretty
  }

  func handleCodexWatchWorktree(runID: String, taskID: String, event: JSONValue) async throws {
    guard library.task(containing: runID)?.id == taskID,
      let requestID = event["requestId"].text,
      let raw = event["automationId"].text, let automationID = UUID(uuidString: raw) else {
      throw AgentFailure(message: "PR 工作树请求缺少有效身份。")
    }
    let call = ModelFunctionCall(id: requestID, name: ModelWatchWorktreeTool.name,
      arguments: JSONValue.object(["reason": event["reason"]]).pretty)
    let output = try executeWatchWorktreeTool(call, runID: runID, expectedAutomationID: automationID)
    let result = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
    try await codexTransport.resolveAutomationRequest(taskID: taskID, requestID: requestID, result: result)
  }

  /// Continue only a successfully finished inspection. Persisted requests survive
  /// preparation failures/restarts, and an existing checkout is recovered, never reset.
  func continueWatchInWorktree(id: UUID, project: String, taskID: String,
    inspectionRunID: String) async throws -> [String] {
    guard let run = library.chatRuns.first(where: { $0.id == inspectionRunID }),
      run.request["automation_id"].text == id.uuidString,
      library.task(containing: inspectionRunID)?.id == taskID else {
      throw AgentFailure(message: "PR 检查结果已不可用或不属于此监控任务。")
    }
    if let prior = run.request["watch_inspection_run_id"].text,
      library.task(containing: prior)?.id == taskID,
      library.chatRuns.first(where: { $0.id == prior })?.request["automation_id"].text == id.uuidString {
      return [prior, inspectionRunID]
    }
    guard run.status == "succeeded", run.request["watch_phase"].text == "inspection",
      let reason = run.result?["watch_worktree_request"].text else { return [inspectionRunID] }
    guard let watch = automationPreferences.items.first(where: {
      $0.id == id && $0.enabled && $0.taskID == taskID && $0.selectedProjects.contains(project)
    }), validatePullRequestWatchTarget(watch), !shuttingDown, !Task.isCancelled,
      library.task(containing: inspectionRunID)?.id == taskID,
      library.tasks.first(where: { $0.id == taskID }).map({
        $0.project == run.project || $0.project == library.managedWorktree(forTaskID: taskID)?.path
      }) == true else {
      return [inspectionRunID]
    }
    let source = library.managedWorktree(forTaskID: taskID)?.source
      ?? library.managedWorktrees.first(where: { $0.path == run.project })?.source ?? run.project
    let record = try await prepareAutomationWorktree(sourcePath: source, taskID: taskID,
      environmentSelection: watch.environmentSelection(for: project), includeSourceChanges: false)
    try Task.checkCancellation()
    guard let current = automationPreferences.items.first(where: {
      $0.id == id && $0.enabled && $0.taskID == taskID && $0.project == watch.project
        && $0.watchedPullRequest?.validatedURL == watch.watchedPullRequest?.validatedURL
    }), validatePullRequestWatchTarget(current), !shuttingDown,
      library.tasks.first(where: { $0.id == taskID }).map({
        $0.project == run.project || $0.project == record.path
      }) == true else {
      return [inspectionRunID]
    }
    var candidate = library
    guard let index = candidate.tasks.firstIndex(where: { $0.id == taskID }) else {
      throw AgentFailure(message: "PR 监控任务已删除。")
    }
    candidate.tasks[index].project = record.path
    var profile = candidate.profiles[source] ?? BuildProfile()
    record.environment?.apply(to: &profile)
    candidate.profiles[record.path] = profile
    try commitLibrary(candidate)
    let prompt = """
      Continue this PR heartbeat in its prepared isolated worktree: \(record.path).
      Inspection requested this authorized repair: \(reason)
      Re-read the live PR head, logs and checks before making changes. The configured checkout remains untouched.

      \(current.prompt)
      """
    guard let repairID = await startChat(prompt, taskID: taskID, automationID: id,
      watchInspectionRunID: inspectionRunID) else {
      // Keep inspection ownership recoverable if model startup fails after creation.
      var rollback = library
      if let index = rollback.tasks.firstIndex(where: { $0.id == taskID }),
        rollback.tasks[index].project == record.path {
        rollback.tasks[index].project = run.project
        try commitLibrary(rollback)
      }
      throw AgentFailure(message: error ?? "PR 修复回合暂时无法启动。")
    }
    await modelTask(runID: repairID)?.value
    guard library.chatRuns.first(where: { $0.id == repairID })?.isActive == false else {
      throw AgentFailure(message: "PR 修复回合尚未结束。")
    }
    return [inspectionRunID, repairID]
  }
}
