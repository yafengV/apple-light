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
      Text("已连接的工具可供会话使用；执行前会在对应任务中请求批准。")
        .appFont(.caption).foregroundStyle(.secondary)
    }.padding(24).frame(minWidth: 560, minHeight: 400)
  }
}
