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
  @Environment(\.isEnabled) private var isEnabled
  @Bindable var store: WorkspaceStore
  let scope: TerminalScope
  let terminalID: UUID
  @State private var detachedFocus: TerminalFocusRequest?
  private var session: TerminalSession? { store.workspace.terminals.session(terminalID, for: scope) }
  private var split: TerminalSession? { store.workspace.terminals.splitSession(for: terminalID, in: scope) }
  private var detached: Bool {
    store.workspaceTabPlacement(WorkspaceContentTab.terminal(terminalID, owner: scope.conversation).id) == .detached
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("终端", systemImage: "terminal").appFont(.caption, weight: .medium)
        Text(store.library.tasks.first { $0.id == scope.conversation }?.title ?? "新任务")
          .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if let session {
          Text(session.displayTitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
          Button { split == nil ? openSplit() : closeSplit() } label: {
            Image(systemName: split == nil ? "rectangle.split.2x1" : "rectangle")
          }.buttonStyle(.plain)
            .help(split == nil ? "向右拆分终端" : "关闭拆分终端")
            .accessibilityLabel(split == nil ? "向右拆分终端" : "关闭拆分终端")
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
        if let split {
          TerminalSplitLayout(fraction: store.workspace.terminals.splitFraction(for: terminalID, in: scope),
            onChange: { store.workspace.terminals.setSplitFraction($0, for: terminalID, in: scope) }) {
            TerminalSessionPane(session: session,
              focus: detached ? detachedFocus : store.terminalFocusRequest,
              canFocus: { canFocus($0, sessionID: session.id) }, restart: restart)
          } trailing: {
            TerminalSessionPane(session: split,
              focus: detached ? detachedFocus : store.terminalFocusRequest,
              canFocus: { canFocus($0, sessionID: split.id) },
              restart: restartSplit, close: closeSplit)
          }
        } else {
          TerminalSessionPane(session: session,
            focus: detached ? detachedFocus : store.terminalFocusRequest,
            canFocus: { canFocus($0, sessionID: session.id) }, restart: restart)
        }
      } else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }.frame(maxHeight: .infinity).task(id: session.map(ObjectIdentifier.init)) {
      guard session != nil else { return }
      if detached {
        detachedFocus = TerminalFocusRequest(scope: scope, sessionID: terminalID)
      } else {
        store.focusTerminal(terminalID)
      }
    }
  }
  private func canFocus(_ request: TerminalFocusRequest, sessionID: UUID) -> Bool {
    guard isEnabled else { return false }
    if detached {
      return !store.shuttingDown && detachedFocus == request && request.scope == scope
        && request.sessionID == sessionID
    }
    return request.sessionID == sessionID && store.canFocusTerminal(request)
  }
  private func restart() {
    _ = store.restartTerminalTab(terminalID)
  }
  private func openSplit() {
    guard let split = store.splitTerminalTab(terminalID) else { return }
    if detached { detachedFocus = TerminalFocusRequest(scope: scope, sessionID: split.id) }
  }
  private func closeSplit() {
    store.closeTerminalSplit(terminalID)
    if detached { detachedFocus = TerminalFocusRequest(scope: scope, sessionID: terminalID) }
  }
  private func restartSplit() {
    guard let split = store.restartTerminalSplit(terminalID) else { return }
    if detached { detachedFocus = TerminalFocusRequest(scope: scope, sessionID: split.id) }
  }
}
