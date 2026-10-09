import Foundation

extension WorkspaceStore {
  /// The checkout and setup already exist. Clone only the frozen native history;
  /// acknowledge its identity and the ready state in one final library write.
  func createPendingWorktreeNativeFork(_ id: String) async throws
    -> (threadID: String, workspace: String)? {
    try Task.checkCancellation()
    guard let record = library.managedWorktrees.first(where: { $0.taskID == id }),
      record.pendingForkSourceTaskID != nil, record.ready, record.setupCompleted == true,
      let task = library.tasks.first(where: { $0.id == id && !$0.archived }),
      task.project == record.path, !shuttingDown else {
      throw AgentFailure(message: "工作树分支已变化，请从任务菜单重试。")
    }
    let config = modelConfiguration(for: id)
    let required = record.nativeForkRequired
      ?? (config.apiProtocol == .codexResponses && task.codexForkOrigin != nil)
    guard required else { return nil }
    guard let origin = task.codexForkOrigin else {
      throw AgentFailure(message: "缺少原生聊天分支来源，工作树已保留。")
    }
    if task.codexThreadID != nil {
      guard task.codexWorkspacePath == record.path else {
        throw AgentFailure(message: "原生分支目录与工作树不一致，请检查后重试。")
      }
      return nil
    }
    guard config.apiProtocol == .codexResponses,
      task.modelSelection?.providerAccount == nil
        || task.modelSelection?.providerAccount == config.credentialAccount else {
      throw AgentFailure(message: "请恢复创建分支时的独立 Responses 服务后继续；工作树和历史已保留。")
    }
    try config.validateEndpoint()
    guard !config.model.isEmpty else { throw AgentFailure(message: "请配置独立模型服务后继续创建分支。") }
    managedTaskPreparationMessage = "正在创建原生聊天分支…"
    var created: (threadID: String, workspace: String)?
    do {
      _ = try await codexTransport.startTurn(taskID: id,
        workspace: URL(fileURLWithPath: record.path, isDirectory: true), executable: executable,
        additionalFolders: library.additionalFolders(for: record.forkSourcePath ?? record.source),
        config: config, key: try ModelKeychain.read(account: config.credentialAccount),
        initialText: "", continuationText: "", images: [], fileAppendix: nil,
        mcpServers: mcpServers, hooks: try hookSettings.sessionBindings(),
        permissions: runtimePermissions(for: id), responses: library.agentResponsePreferences,
        webSearchMode: library.agentWebSearchMode,
        confettiEnabled: confettiEnabled && !appearance.shouldReduceMotion,
        forkOrigin: origin, createForkOnly: true, onForkCreated: { created = ($0, $1) })
      try Task.checkCancellation()
      guard let current = library.tasks.first(where: { $0.id == id && !$0.archived }),
        current.project == task.project, current.codexForkOrigin == origin,
        current.codexThreadID == task.codexThreadID, current.runIDs == task.runIDs,
        library.managedWorktrees.contains(where: {
          $0.taskID == id && $0.path == record.path && $0.pendingForkSourceTaskID == record.pendingForkSourceTaskID
            && $0.ready && $0.setupCompleted == true
        }), let created, created.workspace == record.path,
        codexTransport.isConnected(taskID: id), !shuttingDown else {
        throw AgentFailure(message: "原生分支创建期间记录或连接已改变，工作树已保留供重试。")
      }
      return created
    } catch {
      await Task { await self.codexTransport.discard(taskID: id) }.value
      throw error
    }
  }
}
