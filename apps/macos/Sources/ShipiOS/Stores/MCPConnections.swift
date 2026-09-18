import Foundation

extension WorkspaceStore {
  func connectMCPServer(_ id: UUID) {
    guard !shuttingDown, mcpServersLoaded, let configuration = mcpServers.first(where: { $0.id == id }), configuration.enabled else { return }
    let closing = disconnectMCPServer(id)
    let token = UUID()
    mcpConnectionTokens[id] = token
    mcpConnectionStates[id] = .connecting
    mcpConnectionTasks[id] = Task { [weak self] in
      await closing?.value
      guard let self, !Task.isCancelled, self.mcpConnectionTokens[id] == token else { return }
      do {
        let connection = try MCPConnection(configuration: configuration)
        mcpConnections[id] = connection
        connection.onDisconnect = { [weak self] message in
          guard let self, self.mcpConnectionTokens[id] == token else { return }
          self.disconnectMCPServer(id)
          self.mcpConnectionStates[id] = .failed(message)
        }
        connection.onToolsChanged = { [weak self] in
          guard let self, self.mcpConnectionTokens[id] == token,
            case .connected = self.mcpConnectionStates[id] else { return }
          self.refreshMCPTools(id)
        }
        let tools = try await connection.initialize()
        guard !Task.isCancelled, mcpConnectionTokens[id] == token else { await connection.close(); return }
        mcpConnectionStates[id] = .connected(connection.serverName, tools)
        mcpConnectionTasks[id] = nil
      } catch {
        guard mcpConnectionTokens[id] == token else { return }
        disconnectMCPServer(id)
        mcpConnectionStates[id] = .failed(error.localizedDescription)
      }
    }
  }

  func refreshMCPTools(_ id: UUID) {
    guard mcpConnectionTasks[id] == nil, let connection = mcpConnections[id],
      let token = mcpConnectionTokens[id] else { return }
    mcpRefreshingServers.insert(id)
    mcpConnectionTasks[id] = Task { [weak self] in
      guard let self else { return }
      do {
        let tools = try await connection.listTools()
        guard !Task.isCancelled, mcpConnectionTokens[id] == token else { return }
        mcpConnectionStates[id] = .connected(connection.serverName, tools)
        mcpRefreshingServers.remove(id)
        mcpConnectionTasks[id] = nil
      } catch {
        guard mcpConnectionTokens[id] == token else { return }
        disconnectMCPServer(id)
        mcpConnectionStates[id] = .failed(error.localizedDescription)
      }
    }
  }

  @discardableResult func disconnectMCPServer(_ id: UUID) -> Task<Void, Never>? {
    rejectMCPApprovals(serverID: id)
    mcpConnectionTokens[id] = nil
    mcpConnectionTasks.removeValue(forKey: id)?.cancel()
    mcpConnectionStates[id] = .disconnected
    mcpRefreshingServers.remove(id)
    if let connection = mcpConnections.removeValue(forKey: id) {
      mcpClosingTasks[id] = Task { [weak self] in
        await connection.close()
        self?.mcpClosingTasks[id] = nil
      }
    }
    return mcpClosingTasks[id]
  }

  func shutdownMCPConnections() async {
    for id in Array(mcpPendingApprovals.keys) { resolveMCPApproval(id, decision: .deny) }
    mcpTaskGrants.removeAll()
    let connections = Array(mcpConnections.values)
    mcpConnectionTokens.removeAll()
    for task in mcpConnectionTasks.values { task.cancel() }
    mcpConnectionTasks.removeAll()
    mcpConnections.removeAll()
    mcpConnectionStates.removeAll()
    mcpRefreshingServers.removeAll()
    for connection in connections { await connection.close() }
    for task in Array(mcpClosingTasks.values) { await task.value }
    mcpClosingTasks.removeAll()
  }
}
