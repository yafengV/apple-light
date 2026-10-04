import Foundation

extension WorkspaceStore {
  func backgroundTerminals(taskID: String) -> [CodexBackgroundTerminal] {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return [] }
    return task.runIDs.flatMap { runID in
      guard let run = library.chatRuns.first(where: { $0.id == runID }), !run.isActive else {
        return [CodexBackgroundTerminal]()
      }
      return run.toolExecutions.compactMap { execution in
        guard let entry = codexBackgroundTerminals[execution.id], entry.taskID == taskID,
          entry.runID == runID, entry.running, !entry.cleanupRequested else { return nil }
        return entry
      }
    }
  }

  func backgroundTerminalDocument(_ id: UUID, taskID: String) -> CodexBackgroundTerminalDocument? {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return nil }
    for runID in task.runIDs {
      guard let run = library.chatRuns.first(where: { $0.id == runID }),
        let execution = run.toolExecutions.first(where: {
          $0.id == id && $0.serverID == CodexCommandTimeline.serverID && $0.toolName == "命令"
        }) else { continue }
      let live = codexBackgroundTerminals[id].flatMap {
        $0.taskID == taskID && $0.runID == run.id ? $0 : nil
      }
      let command = live?.command ?? execution.arguments.components(separatedBy: "\n$ ").last ?? ""
      return .init(id: id, title: command.isEmpty ? "后台终端" : command,
        output: live?.output ?? execution.output ?? "")
    }
    return nil
  }

  /// Command notifications outlive their turn stream. A delta without a turn
  /// identity is accepted only when its thread/call identify one live command.
  func recordCodexRuntimeCommand(taskID: String, threadID: String?, event: JSONValue) {
    guard let threadID, let type = event["type"].text,
      let task = library.tasks.first(where: { $0.id == taskID }) else { return }
    if ["task_started", "turn_started"].contains(type) {
      guard task.codexThreadID == threadID,
        let runID = task.runIDs.last(where: { id in library.chatRuns.first { $0.id == id }?.isActive == true }) else { return }
      recordCodexTurnBoundary(runID: runID, taskID: taskID, event: event)
      return
    }
    if type == "shutdown_complete" {
      disconnectBackgroundTerminals(taskID: taskID, threadID: threadID)
      return
    }
    let callID = event["call_id"].text ?? event["item"]["call_id"].text
    guard let callID, !callID.isEmpty else { return }
    let matches = codexBackgroundTerminals.values.filter {
      $0.taskID == taskID && $0.threadID == threadID && $0.callID == callID
        && (event["turn_id"].text == nil || $0.turnID == event["turn_id"].text)
    }
    let runID: String?
    if let turnID = event["turn_id"].text {
      runID = task.runIDs.last { id in
        guard let run = library.chatRuns.first(where: { $0.id == id }) else { return false }
        return run.result?["codex_thread_id"].text == threadID && run.result?["codex_turn_id"].text == turnID
      }
    } else if type == "raw_response_item", event["item"]["type"].text == "function_call_output", !matches.isEmpty {
      runID = matches.count == 1 ? matches[0].runID : nil
    } else if type == "exec_command_output_delta" {
      let live = matches.filter(\.running)
      runID = live.count == 1 ? live[0].runID : nil
    } else {
      runID = task.codexThreadID == threadID ? task.runIDs.last { id in
        library.chatRuns.first { $0.id == id }?.isActive == true
      } : nil
    }
    guard let runID, let run = library.chatRuns.first(where: { $0.id == runID }) else { return }
    switch type {
    case "exec_command_begin":
      guard let turnID = event["turn_id"].text,
        let execution = recordCodexCommand(runID: runID, event: event) else { return }
      if codexBackgroundTerminals[execution.id] == nil {
        codexBackgroundTerminals[execution.id] = .init(id: execution.id, taskID: taskID, runID: runID,
          threadID: threadID, turnID: turnID, callID: callID, processID: event["process_id"].text,
          command: CodexBackgroundTerminal.command(event), bytes: Data((execution.output ?? "").utf8))
      }
    case "exec_command_output_delta":
      guard let existing = matches.first(where: { $0.runID == runID && $0.running }),
        let chunk = event["chunk"].text.flatMap({ Data(base64Encoded: $0) }), !chunk.isEmpty else { return }
      var entry = existing
      entry.bytes.append(contentsOf: chunk.prefix(max(0, 65_536 - entry.bytes.count)))
      codexBackgroundTerminals[entry.id] = entry
      var executions = run.toolExecutions
      guard let index = executions.firstIndex(where: { $0.id == entry.id }) else { return }
      executions[index].output = entry.output
      replaceChat(run, status: run.status, response: run.result?["response"].text ?? "", toolExecutions: executions)
      saveLibrary()
    case "exec_command_end":
      guard let execution = recordCodexCommand(runID: runID, event: event) else { return }
      if var entry = codexBackgroundTerminals[execution.id] {
        entry.running = false; entry.bytes = Data((execution.output ?? "").utf8)
        codexBackgroundTerminals[entry.id] = entry
      }
    case "raw_response_item":
      recordCodexCommandResult(runID: runID, event: event)
      if let current = library.chatRuns.first(where: { $0.id == runID }),
        let execution = current.toolExecutions.first(where: { $0.serverID == CodexCommandTimeline.serverID && $0.callID == callID }),
        var entry = codexBackgroundTerminals[execution.id] {
        entry.bytes = Data((execution.output ?? "").utf8)
        codexBackgroundTerminals[entry.id] = entry
      }
    default: break
    }
  }

  func disconnectBackgroundTerminals(taskID: String, threadID: String? = nil) {
    var changed = false
    for (id, var entry) in codexBackgroundTerminals where entry.taskID == taskID
      && (threadID == nil || entry.threadID == threadID) {
      guard entry.running else { continue }
      entry.running = false; codexBackgroundTerminals[id] = entry
      changed = true
      if let run = library.chatRuns.first(where: { $0.id == entry.runID }) {
        var executions = run.toolExecutions
        if let index = executions.firstIndex(where: { $0.id == id && $0.status == .running }) {
          executions[index].status = .cancelled
          replaceChat(run, status: run.status, response: run.result?["response"].text ?? "", toolExecutions: executions)
        }
      }
    }
    if changed { saveLibrary() }
  }

  func cleanBackgroundTerminals(taskID: String, selectedID: UUID,
    notices destination: WorkspaceNotices? = nil) async {
    guard backgroundTerminalCleanup[taskID] == nil,
      backgroundTerminals(taskID: taskID).contains(where: { $0.id == selectedID }) else { return }
    backgroundTerminalCleanup[taskID] = selectedID
    let requestedIDs = Set(codexBackgroundTerminals.values.filter { $0.taskID == taskID && $0.running }.map(\.id))
    defer { backgroundTerminalCleanup[taskID] = nil }
    do {
      try await codexTransport.cleanBackgroundTerminals(taskID: taskID)
      // This acknowledges submission only. Late output/end events still route
      // to these identities; the UI stops offering another cleanup request.
      for (id, var entry) in codexBackgroundTerminals where requestedIDs.contains(id) && entry.running {
        entry.cleanupRequested = true; codexBackgroundTerminals[id] = entry
      }
    } catch {
      (destination ?? notices).show(id: "background-terminal-clean:\(taskID)", title: "无法停止后台终端",
        description: error.localizedDescription, level: .error)
    }
  }

  @discardableResult func openBackgroundTerminal(_ id: UUID, in placement: WorkspaceTabPlacement = .right) -> Bool {
    let owner = currentWorkspaceTabOwner
    guard placement != .bottom, backgroundTerminalDocument(id, taskID: owner) != nil else { return false }
    let tab = WorkspaceContentTab.backgroundTerminal(id, owner: owner)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab); workspaceTabPlacements[tab.id] = placement }
    activateWorkspaceTab(tab.id)
    return true
  }
}
