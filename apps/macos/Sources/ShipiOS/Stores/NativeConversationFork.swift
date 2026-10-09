import Foundation

extension WorkspaceStore {
  /// Freeze the source boundary, create its actual Core child without a model turn,
  /// then merge only that child into the latest library. No unpublished child navigates.
  func persistConversationFork(_ id: String, through runID: String? = nil,
    commandDraft: String? = nil) async throws -> WorkspaceTask {
    guard forkSourceIsAvailable(id, through: runID), let source = library.tasks.first(where: { $0.id == id }) else {
      throw AgentFailure(message: "聊天来源已不可用，请返回任务列表。")
    }
    var frozen = library
    var fork = try frozen.forkConversation(taskID: id, through: runID, availableRuns: taskWindowRuns(id))
    let config = modelConfiguration(for: id)
    // Imported/text conversations have no native rollout to clone. Preserve their
    // completed text history through the existing first-turn context path.
    guard config.apiProtocol == .codexResponses, let origin = fork.codexForkOrigin else {
      return try persistNonNativeFork(id, through: runID,
        consumeCommand: commandDraft != nil && library.drafts[id] == commandDraft)
    }
    try config.validateEndpoint()
    guard !config.model.isEmpty else { throw AgentFailure(message: "请配置独立模型服务后重试。") }
    let permissions = runtimePermissions(for: id)
    fork.modelSelection = .init(model: config.model, reasoning: config.reasoning,
      providerAccount: config.credentialAccount, apiProtocol: config.apiProtocol)
    frozen.taskRuntimePreferences[fork.id] = permissions
    let workspace = source.project.isEmpty
      ? try projectlessWorkspace(taskID: fork.id, create: true)
      : URL(fileURLWithPath: source.project, isDirectory: true)
    let copied = Set(fork.runIDs)
    let snapshots = frozen.forkRuns.filter { copied.contains($0.id) }
    var created: (threadID: String, workspace: String)?
    do {
      _ = try await codexTransport.startTurn(taskID: fork.id, workspace: workspace, executable: executable,
        additionalFolders: frozen.additionalFolders(for: source.project), config: config,
        key: try ModelKeychain.read(account: config.credentialAccount),
        initialText: "", continuationText: "", images: [], fileAppendix: nil,
        mcpServers: mcpServers, hooks: try hookSettings.sessionBindings(), permissions: permissions,
        responses: frozen.agentResponsePreferences, webSearchMode: frozen.agentWebSearchMode,
        confettiEnabled: confettiEnabled && !appearance.shouldReduceMotion,
        forkOrigin: origin, createForkOnly: true,
        onForkCreated: { created = ($0, $1) })
      try Task.checkCancellation()
      guard forkSourceIsAvailable(id, through: runID),
        let current = library.tasks.first(where: { $0.id == id }),
        current.project == source.project, current.codexThreadID == source.codexThreadID,
        current.codexWorkspacePath == source.codexWorkspacePath,
        current.codexForkOrigin == source.codexForkOrigin,
        let created, codexTransport.isConnected(taskID: fork.id) else {
        throw AgentFailure(message: "创建期间聊天来源或连接已改变，请重试。")
      }
      fork.codexThreadID = created.threadID
      fork.codexWorkspacePath = created.workspace
      var latest = library
      latest.tasks.insert(fork, at: 0)
      latest.forkRuns.append(contentsOf: snapshots)
      latest.taskRuntimePreferences[fork.id] = permissions
      if let commandDraft, latest.drafts[id] == commandDraft { latest.drafts[id] = "" }
      if source.project.isEmpty { latest.projectlessTaskDirectories[fork.id] = workspace.path }
      for runID in copied {
        latest.forkRunOrigins[runID] = frozen.forkRunOrigins[runID]
        latest.notes[runID] = frozen.notes[runID]
        latest.runBranches[runID] = frozen.runBranches[runID]
        latest.runImages[runID] = frozen.runImages[runID]
        latest.runFiles[runID] = frozen.runFiles[runID]
      }
      latest.shareManagedWorktree(sourceTaskID: id, fork: fork)
      try commitLibrary(latest)
      if fork.project == currentProjectKey { runs.append(contentsOf: snapshots) }
      return fork
    } catch {
      await Task { await self.codexTransport.discard(taskID: fork.id) }.value
      throw error
    }
  }
}
