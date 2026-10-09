import SwiftUI

/// Waits for saved data before resolving a system-restored content window.
struct WorkspaceTabWindowSceneView: View {
  @Bindable var store: WorkspaceStore
  @Binding var route: WorkspaceTabWindowRoute?
  @Environment(\.dismiss) private var dismiss
  private var restoration: DetachedWorkspaceTabRestoration { store.detachedWorkspaceTabRestoration(route) }

  var body: some View {
    Group {
      if case .ready = restoration, let route,
        store.workspaceTabs.contains(where: { $0.id == route.tabID }) {
        WorkspaceTabWindowView(store: store, tabID: route.tabID)
      } else {
        restorationContent.frame(minWidth: 620, minHeight: 520)
          .focusedSceneValue(\.taskWindowCommands,
            TaskWindowCommandContext(enabled: ["tab-close"], perform: { _ in closeWindow() }))
      }
    }
    .disabled(store.shuttingDown)
    .background(FileRecoveryWindowCloseGuard(prepare: { store.prepareDetachedWindowClose(route?.tabID) })
      .frame(width: 0, height: 0))
    .task(id: restoration) {
      switch restoration {
      case .ready:
        if let route, let migrated = store.prepareDetachedWorkspaceTab(route) { self.route = migrated }
      case .close: closeWindow()
      case .loading, .failed: break
      }
    }
  }

  private func closeWindow() {
    guard store.prepareDetachedWindowClose(route?.tabID) else { return }
    dismiss()
  }

  @ViewBuilder private var restorationContent: some View {
    switch restoration {
    case .failed(let message):
      ContentUnavailableView {
        Label("无法恢复标签页窗口", systemImage: "exclamationmark.triangle")
      } description: { Text(message) } actions: {
        Button("重试") { Task { await store.restore() } }
        Button("关闭窗口") { closeWindow() }
      }
    case .loading, .ready: ProgressView("正在恢复标签页…")
    case .close: Color.clear
    }
  }
}
