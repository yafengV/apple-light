import Foundation

extension WorkspaceStore {
  @discardableResult func openSubagents(taskID: String? = nil, in placement: WorkspaceTabPlacement = .right) -> Bool {
    let owner = taskID ?? currentWorkspaceTabOwner
    guard owner == currentWorkspaceTabOwner, placement != .bottom,
      library.tasks.contains(where: { $0.id == owner }) else { return false }
    let tab = WorkspaceContentTab.subagents(owner: owner)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab); workspaceTabPlacements[tab.id] = placement }
    activateWorkspaceTab(tab.id)
    return true
  }
  func subagents(taskID: String) -> [CodexSubagent] {
    library.tasks.first { $0.id == taskID }?.codexSubagents ?? []
  }

  /// Reconnect the recorded root without submitting or compacting a parent turn.
  func prepareSubagent(taskID: String, agent: CodexSubagent) async throws {
    func owner() throws -> WorkspaceTask {
      guard libraryLoaded, !shuttingDown, !libraryRecoveryBlocksInteraction,
        let task = library.tasks.first(where: { $0.id == taskID }),
        task.codexThreadID == agent.rootThreadID,
        subagents(taskID: taskID).contains(where: { $0.id == agent.id }) else {
        throw AgentFailure(message: "子任务所属会话已变化，请返回列表。")
      }
      return task
    }
    _ = try owner()
    try await prepareSubagentRoot(taskID: taskID, expectedRoot: agent.rootThreadID)
    _ = try owner()
    // A closed selection expresses read-only history navigation even when
    // reconnecting has already reconciled that stale UI row with an open edge.
    if agent.status == .shutdown || subagents(taskID: taskID).first(where: { $0.id == agent.id })?.status == .shutdown { return }
    let row = try await codexTransport.loadSubagent(taskID: taskID, rootThreadID: agent.rootThreadID, childThreadID: agent.threadID)
    _ = try owner()
    guard let statusName = row["status"].text, let status = CodexSubagentStatus(rawValue: statusName),
      let loaded = row["loaded"].boolean, loaded else { throw AgentFailure(message: "子任务未能加载，请重新加载。") }
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      let childIndex = library.tasks[index].codexSubagents?.firstIndex(where: { $0.id == agent.id }) else {
      throw AgentFailure(message: "子任务所属会话已变化。")
    }
    // A newer monitor snapshot may already describe a turn started elsewhere.
    if library.tasks[index].codexSubagents![childIndex].loaded { return }
    var child = library.tasks[index].codexSubagents![childIndex]
    child.loaded = loaded; child.status = status
    child.parentThreadID = row["parentThreadId"].text ?? child.parentThreadID
    child.nickname = row["nickname"].text ?? child.nickname; child.role = row["role"].text ?? child.role
    child.model = row["model"].text ?? child.model; child.reasoningEffort = row["reasoningEffort"].text ?? child.reasoningEffort
    child.depth = row["depth"].int ?? child.depth; child.preview = row["preview"].text ?? child.preview
    child.recencyAtMs = row["recencyAtMs"].int ?? child.recencyAtMs
    child.objective = row["objective"].text ?? child.objective
    library.tasks[index].codexSubagents![childIndex] = child
    saveLibrary()
  }

  /// Reconcile durable descendants without opening their runtimes or starting
  /// another parent model turn. Both main and detached overview panels use this.
  func refreshSubagents(taskID: String, expectedRoot: String) async throws {
    try await prepareSubagentRoot(taskID: taskID, expectedRoot: expectedRoot)
    try await codexTransport.refreshSubagents(taskID: taskID, rootThreadID: expectedRoot)
  }

  private func prepareSubagentRoot(taskID: String, expectedRoot: String) async throws {
    func owner() throws -> WorkspaceTask {
      guard libraryLoaded, !shuttingDown, !libraryRecoveryBlocksInteraction,
        let task = library.tasks.first(where: { $0.id == taskID }), task.codexThreadID == expectedRoot else {
        throw AgentFailure(message: "子任务所属会话已变化，请返回列表。")
      }
      return task
    }
    _ = try owner()
    await Task.yield()
    try await codexTransport.waitForParentPreparation(taskID: taskID)
    let task = try owner()
    if !codexTransport.isConnected(taskID: taskID) {
      let config = modelConfiguration(for: taskID)
      guard config.apiProtocol == .codexResponses, let origin = CodexResumeOrigin(task: task) else {
        throw AgentFailure(message: "原 Codex 会话配置或历史已不可用。")
      }
      try config.validateEndpoint()
      let workspace = URL(fileURLWithPath: task.project.isEmpty ? origin.workspace : task.project)
      guard FileManager.default.fileExists(atPath: workspace.path) else {
        throw AgentFailure(message: "会话工作目录已不可用。")
      }
      _ = try await codexTransport.startTurn(taskID: taskID, workspace: workspace, executable: executable,
        additionalFolders: library.additionalFolders(for: task.project), config: config,
        key: try ModelKeychain.read(account: config.credentialAccount), initialText: "", continuationText: "", images: [],
        fileAppendix: nil, readOnly: task.isSideChat, mcpServers: mcpServers,
        hooks: task.isSideChat ? [] : try hookSettings.sessionBindings(), permissions: runtimePermissions(for: taskID),
        responses: library.agentResponsePreferences, webSearchMode: library.agentWebSearchMode,
        confettiEnabled: confettiEnabled && !appearance.shouldReduceMotion, connectOnly: true, resumeOrigin: origin)
    }
    _ = try owner()
    try Task.checkCancellation()
  }

  func activeSubagents(taskID: String) -> [CodexSubagent] {
    guard let root = library.tasks.first(where: { $0.id == taskID })?.codexThreadID else { return [] }
    return subagents(taskID: taskID).filter { $0.rootThreadID == root && $0.working }
  }

  func recordSubagentSnapshot(taskID: String, threadID: String?, event: JSONValue) {
    guard let threadID, let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      library.tasks[index].codexThreadID == threadID else { return }
    var assembler = subagentSnapshotAssemblers[taskID] ?? .init()
    let snapshot = assembler.append(event, root: threadID)
    subagentSnapshotAssemblers[taskID] = assembler
    guard let snapshot else { return }
    guard let version = assembler.completedRevision,
      version > (subagentSnapshotRevisions[taskID] ?? 0) else { return }
    subagentSnapshotRevisions[taskID] = version
    let previous = library.tasks[index].codexSubagents ?? []
    var next = previous.filter { $0.rootThreadID != threadID }.map { entry in
      var entry = entry; entry.disconnect(); return entry
    }
    for var row in snapshot {
      if let old = previous.first(where: { $0.id == row.id }), !row.loaded {
        row.parentThreadID = row.parentThreadID ?? old.parentThreadID
        row.nickname = row.nickname ?? old.nickname; row.role = row.role ?? old.role
        row.depth = row.depth ?? old.depth; row.model = row.model ?? old.model
        row.reasoningEffort = row.reasoningEffort ?? old.reasoningEffort
        row.preview = row.preview ?? old.preview
        row.recencyAtMs = row.recencyAtMs ?? old.recencyAtMs
        row.objective = row.objective ?? old.objective
        if row.status == .notLoaded, !old.status.working { row.status = old.status }
      }
      next.append(row)
    }
    guard next != previous else { return }
    library.tasks[index].codexSubagents = next
    saveLibrary()
    notifySubagentRequests(taskID: taskID)
  }

  func recordSubagentEvent(taskID: String, threadID: String?, event: JSONValue) {
    guard let threadID, library.tasks.first(where: { $0.id == taskID })?.codexThreadID == threadID,
      let child = event["childThreadId"].text,
      let agent = subagents(taskID: taskID).first(where: { $0.rootThreadID == threadID && $0.threadID == child }) else { return }
    var state = subagentLiveStates[agent.id] ?? .init()
    if event["type"].text == "shipios_subagent_approval_state" { state.receiveApproval(event, child: child) }
    else if event["type"].text == "shipios_subagent_elicitation_state" { state.receiveElicitation(event, child: child) }
    else { state.append(event, child: child) }
    subagentLiveStates[agent.id] = state
    notifySubagentRequests(taskID: taskID)
  }

  func resolveSubagentApproval(taskID: String, agent: CodexSubagent, request: SubagentApprovalRequest, choice: Int) async {
    guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
      subagents(taskID: taskID).contains(where: { $0.id == agent.id && $0.loaded }),
      subagentLiveStates[agent.id]?.error == nil,
      let status = subagentLiveStates[agent.id]?.approvals[request.id], status.turnID == request.turnID,
      status.phase == .pending, request.decisions.indices.contains(choice),
      !subagentApprovalBusy.contains(request.id) else { return }
    subagentApprovalBusy.insert(request.id); subagentApprovalErrors.removeValue(forKey: request.id)
    defer { subagentApprovalBusy.remove(request.id) }
    do {
      try await codexTransport.resolveSubagentApproval(taskID: taskID, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, request: request, choice: choice)
    } catch {
      guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
        subagentLiveStates[agent.id] != nil else { return }
      subagentApprovalErrors[request.id] = error.localizedDescription
    }
  }

  func resolveSubagentElicitation(taskID: String, agent: CodexSubagent, request: SubagentElicitationRequest,
    choice: SubagentElicitationRequest.Choice, content: JSONValue?) async {
    guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
      subagents(taskID: taskID).contains(where: { $0.id == agent.id && $0.loaded }),
      subagentLiveStates[agent.id]?.error == nil,
      let status = subagentLiveStates[agent.id]?.elicitations[request.id], status.turnID == request.turnID,
      status.phase == .pending, request.allows(choice, content: content),
      !subagentElicitationBusy.contains(request.id) else { return }
    subagentElicitationBusy.insert(request.id); subagentElicitationErrors.removeValue(forKey: request.id)
    defer { subagentElicitationBusy.remove(request.id) }
    do {
      try await codexTransport.resolveSubagentElicitation(taskID: taskID, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, request: request, choice: choice, content: content)
    } catch {
      guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
        subagentLiveStates[agent.id] != nil else { return }
      subagentElicitationErrors[request.id] = error.localizedDescription
    }
  }

  func stopSubagent(taskID: String, agent: CodexSubagent, expectedTurnID: String) async {
    guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
      subagents(taskID: taskID).contains(where: { $0.id == agent.id && $0.working }),
      !expectedTurnID.isEmpty, subagentStopBusy[agent.id] == nil else { return }
    subagentStopBusy[agent.id] = expectedTurnID; subagentStopErrors.removeValue(forKey: agent.id)
    defer { if subagentStopBusy[agent.id] == expectedTurnID { subagentStopBusy.removeValue(forKey: agent.id) } }
    do {
      try await codexTransport.interruptSubagent(taskID: taskID, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, expectedTurnID: expectedTurnID)
    } catch {
      guard library.tasks.first(where: { $0.id == taskID })?.codexThreadID == agent.rootThreadID,
        subagentStopBusy[agent.id] == expectedTurnID else { return }
      subagentStopErrors[agent.id] = error.localizedDescription
    }
  }

  func disconnectSubagents(taskID: String) {
    subagentSnapshotAssemblers.removeValue(forKey: taskID)
    subagentSnapshotRevisions.removeValue(forKey: taskID)
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      var rows = library.tasks[index].codexSubagents else { return }
    for row in rows {
      subagentStopBusy.removeValue(forKey: row.id); subagentStopErrors.removeValue(forKey: row.id)
      for token in subagentLiveStates[row.id]?.approvals.keys ?? Dictionary<String, SubagentApprovalStatus>().keys {
        subagentApprovalBusy.remove(token); subagentApprovalErrors.removeValue(forKey: token)
      }
      for token in subagentLiveStates[row.id]?.elicitations.keys ?? Dictionary<String, SubagentElicitationStatus>().keys {
        subagentElicitationBusy.remove(token); subagentElicitationErrors.removeValue(forKey: token)
      }
      subagentLiveStates.removeValue(forKey: row.id)
      subagentNotifiedRequests = subagentNotifiedRequests.filter { !$0.hasPrefix(row.id + ":") }
    }
    let before = rows
    for i in rows.indices { rows[i].disconnect() }
    guard before != rows else { return }
    library.tasks[index].codexSubagents = rows
    saveLibrary()
  }
}
