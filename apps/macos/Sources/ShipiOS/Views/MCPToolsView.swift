import SwiftUI

struct MCPToolsView: View {
  @Bindable var store: WorkspaceStore
  let serverID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  private var state: MCPConnectionState { store.mcpConnectionStates[serverID] ?? .disconnected }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("MCP 工具").appFont(.title2, weight: .semibold)
        Spacer()
        if store.mcpRefreshingServers.contains(serverID) { ProgressView().controlSize(.small) }
        Button("刷新") { store.refreshMCPTools(serverID) }
          .disabled(store.mcpRefreshingServers.contains(serverID) || store.mcpConnections[serverID] == nil)
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text(state.label).foregroundStyle(.secondary)
      TextField("搜索工具…", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if case .failed(let message) = state { Text(message).foregroundStyle(.red) }
          ForEach(state.tools.filter { query.isEmpty || ($0.name + " " + $0.title + " " + $0.summary).localizedStandardContains(query) }) { tool in
            DisclosureGroup {
              Toggle("始终允许此工具（自定义 API 会话）", isOn: Binding(
                get: { store.persistentMCPToolAllowed(serverID: serverID, tool: tool) },
                set: { _ = store.setPersistentMCPToolAllowed($0, serverID: serverID, tool: tool) }
              ))
              .help("授权仅对当前 MCP 服务器配置和工具定义有效；变更后需重新批准。Codex Core 会话仍逐次请求批准。")
              Text(tool.inputSchema.pretty).appFont(.caption, design: .monospaced).textSelection(.enabled)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(tool.title).appFont(.headline)
                Text(tool.name).appFont(.caption, design: .monospaced)
                if !tool.summary.isEmpty { Text(tool.summary).foregroundStyle(.secondary) }
              }.textSelection(.enabled)
            }
            Divider()
          }
          if state.tools.isEmpty { Text("服务器未提供工具，或当前连接不可用。").foregroundStyle(.secondary) }
        }
      }
      if let error = store.mcpServersError { Text(error).foregroundStyle(.red).appFont(.caption) }
      Text("已连接的工具可供会话使用；未持久授权的调用会在对应任务中请求批准。")
        .appFont(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(minWidth: 560, minHeight: 400)
  }
}
