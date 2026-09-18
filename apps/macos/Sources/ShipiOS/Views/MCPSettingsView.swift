import SwiftUI

struct MCPSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var toolsServerID: UUID?
  private func matches(_ text: String) -> Bool {
    store.pluginSettingsQuery.split(whereSeparator: \.isWhitespace)
      .allSatisfy { text.localizedStandardContains(String($0)) }
  }
  private var servers: [MCPServerConfiguration] {
    store.mcpServers.filter { matches($0.name + " " + $0.transport.title) }
  }
  private var plugins: [PluginInstallation] {
    store.pluginPreferences.installed.filter { $0.components.mcpServers > 0 && matches($0.name + " " + $0.id) }
  }
  var body: some View {
    Form {
      Section("自定义 MCP 服务器") {
        if store.mcpServersLoading { ProgressView("正在读取 MCP 配置…") }
        else if servers.isEmpty {
          ContentUnavailableView(store.pluginSettingsQuery.isEmpty ? "尚未添加 MCP 服务器" : "没有匹配的服务器",
            systemImage: "network", description: Text("通过“添加 MCP 服务器”配置 STDIO 或 Streamable HTTP 服务。"))
            .frame(maxWidth: .infinity)
        } else {
          ForEach(servers) { server in
            HStack(spacing: 12) {
              Image(systemName: "network")
              Button { store.openMCPServerEditor(server.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(server.name).appFont(.headline)
                  Text(server.transport.title + " · " + (server.enabled ? (store.mcpConnectionStates[server.id] ?? .disconnected).label : "已停用"))
                    .appFont(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.buttonStyle(.plain).accessibilityLabel("编辑 MCP 服务器：\(server.name)")
              connectionControls(server)
              Toggle("启用 MCP 服务器：\(server.name)", isOn: Binding(
                get: { store.mcpServers.first { $0.id == server.id }?.enabled ?? false },
                set: { _ = store.setMCPServerEnabled($0, id: server.id) }))
                .labelsHidden().disabled(!store.mcpServersLoaded)
            }.padding(.vertical, 4)
            if case .failed(let message) = store.mcpConnectionStates[server.id] {
              Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
          }
        }
      }.settingsSearchTarget(.mcpInstalled)
      if !plugins.isEmpty {
        Section("插件中的 MCP 声明") {
          ForEach(plugins) { plugin in
            HStack {
              Button(plugin.name) { store.openPluginDetail(plugin.id) }.buttonStyle(.plain)
              Spacer()
              Text("\(plugin.components.mcpServers) 个服务器").foregroundStyle(.secondary)
            }.padding(.vertical, 8)
          }
        }
      }
      if let error = store.mcpServersError {
        Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
      Section {
        Button("重新加载") { Task { await store.loadMCPServers() } }
          .disabled(store.mcpServersLoading)
      }
    }.settingsFormStyle().appSurface()
      .sheet(isPresented: Binding(get: { toolsServerID != nil }, set: { if !$0 { toolsServerID = nil } })) {
        if let id = toolsServerID {
          MCPToolsView(store: store, serverID: id)
        }
      }
  }

  @ViewBuilder private func connectionControls(_ server: MCPServerConfiguration) -> some View {
    switch store.mcpConnectionStates[server.id] ?? .disconnected {
    case .connecting:
      ProgressView().controlSize(.small)
      Button("取消") { store.disconnectMCPServer(server.id) }
    case .connected:
      Button("工具") { toolsServerID = server.id }
      Button("断开") { store.disconnectMCPServer(server.id) }
    case .disconnected, .failed:
      Button("连接") { store.connectMCPServer(server.id) }
        .disabled(!server.enabled || !store.mcpServersLoaded)
    }
  }
}
