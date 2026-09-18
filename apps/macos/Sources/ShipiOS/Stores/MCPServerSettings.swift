import Foundation

extension WorkspaceStore {
  func loadMCPServers() async {
    guard !mcpServersLoading else { return }
    mcpServersLoading = true
    mcpServersLoaded = false
    await shutdownMCPConnections()
    defer { mcpServersLoading = false }
    let root = dataRoot
    do {
      mcpServers = try await Task.detached(priority: .userInitiated) {
        try MCPServerStorage.load(root: root)
      }.value
      mcpServersLoaded = true
      mcpServersError = nil
    } catch { mcpServersError = error.localizedDescription }
  }

  func openMCPServerEditor(_ id: UUID? = nil) {
    guard mcpServersLoaded else { return }
    if let id {
      guard let server = mcpServers.first(where: { $0.id == id }) else { return }
      mcpServerEditor = server
    } else { mcpServerEditor = MCPServerConfiguration() }
    pluginSettingsSection = .mcpServers
    settingsSearchRequest = nil
    mcpServersError = nil
  }

  @discardableResult func saveMCPServer(_ server: MCPServerConfiguration) -> Bool {
    guard mcpServersLoaded else { return false }
    do {
      let validated = try validatedMCPServerEdit(server)
      var candidate = mcpServers
      if let index = candidate.firstIndex(where: { $0.id == server.id }) {
        if validated.isEquivalent(to: candidate[index]) {
          mcpServerEditor = nil
          mcpServersError = nil
          return true
        }
        candidate[index] = validated
      } else { candidate.append(validated) }
      try MCPServerStorage.save(candidate, root: dataRoot)
      disconnectMCPServer(server.id)
      mcpServers = candidate
      mcpServerEditor = nil
      mcpServersError = nil
      return true
    } catch { mcpServersError = error.localizedDescription; return false }
  }

  func mcpServerEditState(_ server: MCPServerConfiguration) -> MCPServerEditState {
    do {
      let validated = try validatedMCPServerEdit(server)
      if let original = mcpServers.first(where: { $0.id == server.id }), validated.isEquivalent(to: original) {
        return .unchanged
      }
      return .ready
    } catch { return .invalid(error.localizedDescription) }
  }

  private func validatedMCPServerEdit(_ server: MCPServerConfiguration) throws -> MCPServerConfiguration {
    let validated = try server.validated()
    if let original = mcpServers.first(where: { $0.id == server.id }),
      original.transport != validated.transport || original.name != validated.name {
      throw AgentFailure(message: "更换 MCP 名称或类型前，请先卸载原配置。")
    }
    guard !mcpServers.contains(where: { $0.id != server.id && $0.name.lowercased() == validated.name.lowercased() }) else {
      throw AgentFailure(message: "已存在同名 MCP 服务器，请使用其他名称。")
    }
    return validated
  }

  @discardableResult func setMCPServerEnabled(_ enabled: Bool, id: UUID) -> Bool {
    guard mcpServersLoaded, let index = mcpServers.firstIndex(where: { $0.id == id }) else { return false }
    var candidate = mcpServers
    candidate[index].enabled = enabled
    guard persistMCPServers(candidate) else { return false }
    if enabled { connectMCPServer(id) } else { disconnectMCPServer(id) }
    return true
  }

  @discardableResult func removeMCPServer(_ id: UUID) -> Bool {
    guard mcpServersLoaded, mcpServers.contains(where: { $0.id == id }) else { return false }
    guard persistMCPServers(mcpServers.filter { $0.id != id }) else { return false }
    disconnectMCPServer(id)
    mcpConnectionStates[id] = nil
    if mcpServerEditor?.id == id { mcpServerEditor = nil }
    return true
  }

  private func persistMCPServers(_ candidate: [MCPServerConfiguration]) -> Bool {
    do {
      try MCPServerStorage.save(candidate, root: dataRoot)
      mcpServers = candidate
      mcpServersError = nil
      return true
    } catch { mcpServersError = error.localizedDescription; return false }
  }
}
