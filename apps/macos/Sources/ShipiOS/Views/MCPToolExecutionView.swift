import SwiftUI

struct MCPToolExecutionView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  let execution: MCPToolExecution
  @State private var expanded = false
  @State private var showingRaw = false
  @FocusState private var approveFocused: Bool
  @Environment(\.mcpApprovalSurfaceVisible) private var approvalSurfaceVisible
  private var awaiting: Bool {
    run.isActive && execution.status == .awaitingApproval && store.mcpPendingApprovals[execution.id] != nil
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      DisclosureGroup(isExpanded: Binding(get: { expanded || awaiting }, set: { expanded = $0 })) {
        VStack(alignment: .leading, spacing: 10) {
          ScrollView {
            Text(execution.arguments).appFont(.caption, design: .monospaced).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 220)
          if let output = execution.output {
            MCPResultView(output: output)
              .environment(\.mcpApprovalSurfaceVisible, approvalSurfaceVisible && (expanded || awaiting))
            Button(execution.serverID == CodexCommandTimeline.serverID ? "查看工具输出" : "查看完整工具输出") {
              showingRaw = true
            }
          }
        }.padding(.top, 8)
      } label: {
        HStack {
          Image(systemName: awaiting ? "hand.raised" : "wrench.and.screwdriver")
          Text(execution.serverName + "." + execution.toolName).lineLimit(1)
          Spacer()
          Text(execution.label).foregroundStyle(.secondary)
        }.appFont(.caption)
      }
      if awaiting {
        Text("允许此工具使用上方参数执行操作？").appFont(.callout)
        HStack {
          Button("拒绝") { store.resolveMCPApproval(execution.id, decision: .deny) }
            .help("拒绝当前请求 " + store.shortcuts.label("approval-decline"))
          Spacer()
          if execution.serverID != CodexCommandTimeline.serverID {
            Menu("允许…") {
              Button("在本任务中允许此工具") { store.resolveMCPApproval(execution.id, decision: .allowTask) }
            }
          }
          Button("允许本次") { store.resolveMCPApproval(execution.id, decision: .allowOnce) }
            .buttonStyle(.borderedProminent)
            .focused($approveFocused)
            .help("批准当前请求 " + store.shortcuts.label("approval-approve"))
        }
      }
    }.background(MCPApprovalFocusBridge(pending: awaiting && approvalSurfaceVisible) {
      approveFocused = true
    }.frame(width: 0, height: 0))
      .padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(awaiting ? Color.accentColor.opacity(0.5) : .primary.opacity(0.06)))
      .sheet(isPresented: $showingRaw) {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            Text(execution.serverName + "." + execution.toolName).appFont(.headline)
            Spacer()
            Button("关闭") { showingRaw = false }.keyboardShortcut(.cancelAction)
          }
          ScrollView {
            Text(execution.output ?? "").appFont(.body, design: .monospaced).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }.padding(24).frame(minWidth: 560, minHeight: 360)
      }
  }
}
