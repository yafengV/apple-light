import SwiftUI

struct TerminalPanel: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    if let tab = store.activeBottomWorkspaceContentTab, let id = tab.terminalID,
      let scope = store.terminalScope(for: tab) {
      TerminalTabPanel(store: store, scope: scope, terminalID: id).id(id)
    }
  }
}

struct TerminalTabPanel: View {
  @Bindable var store: WorkspaceStore
  let scope: TerminalScope
  let terminalID: UUID
  @State private var session: TerminalSession?
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("终端", systemImage: "terminal").appFont(.caption, weight: .medium)
        Text(store.library.tasks.first { $0.id == scope.conversation }?.title ?? "新任务")
          .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if let session {
          Text(session.title).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          if session.status == .running {
            Button { session.stop() } label: { Image(systemName: "stop") }
              .buttonStyle(.plain).help("结束此任务的终端会话").accessibilityLabel("结束终端会话")
          }
          Button { restart() } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.plain).help("结束当前会话并重新打开终端").accessibilityLabel("重新打开终端")
        }
        if store.workspaceTabPlacement(WorkspaceContentTab.terminal(
          terminalID, owner: scope.conversation).id) == .bottom {
          Button { store.hideTerminalPanel() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).help("隐藏终端，保留会话").accessibilityLabel("隐藏终端")
        }
      }.padding(10)
        .contextMenu { Button("恢复默认终端高度") { store.resetTerminalSize() } }
      Divider()
      if let session {
        TerminalHost(session: session, focus: store.terminalFocusRequest, canFocus: store.canFocusTerminal).id(session.id)
        if session.status != .running {
          HStack {
            Text(session.status.label).appFont(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("重新打开") { restart() }.controlSize(.small)
          }.padding(.horizontal, 10).padding(.vertical, 6)
        }
      } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }.frame(maxHeight: .infinity).task {
      session = store.workspace.terminals.session(terminalID, for: scope)
      store.focusTerminal(terminalID)
    }
  }
  private func restart() {
    session = store.restartTerminalTab(terminalID)
    store.focusTerminal(session?.id)
  }
}
