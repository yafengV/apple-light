import AppKit
import SwiftUI

struct WorkspaceTabContentView: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab

  var body: some View {
    switch tab {
    case .browser(let id, _):
      BrowserPanel(
        store: store, session: store.workspace.browser, showsTabStrip: false, tabID: id)
    case .review:
      GitReviewView(store: store, workspace: store.workspace)
    case .terminal(let id, _):
      if let scope = store.terminalScope(for: tab) {
        TerminalTabPanel(store: store, scope: scope, terminalID: id)
      }
    }
  }
}

struct WorkspaceSidePanel: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    VStack(spacing: 0) {
      if store.showingWorkspaceTabs {
        HStack(spacing: 0) {
          WorkspaceTabStrip(store: store, placement: .right, includesChat: false)
          Button {
            store.showingInspector = false
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .padding(.trailing, 10)
          .help("隐藏右侧面板")
          .accessibilityLabel("隐藏右侧面板")
        }
        Divider()
      }
      if let tab = store.activeRightWorkspaceContentTab {
        WorkspaceTabContentView(store: store, tab: tab)
      } else {
        ContentUnavailableView("没有打开的标签页", systemImage: "sidebar.right")
      }
    }
  }
}

struct WorkspaceTabWindowView: View {
  @Bindable var store: WorkspaceStore
  let tabID: String
  @Environment(\.openWindow) private var openWindow
  @State private var pinnedToFront = false

  private var tab: WorkspaceContentTab? {
    store.workspaceTabs.first { $0.id == tabID }
  }

  var body: some View {
    Group {
      if let tab {
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            Label(store.workspaceTabTitle(tab), systemImage: tab.icon).lineLimit(1)
            Spacer()
            Button("聚焦聊天") {
              store.activateChatTab()
              openWindow(id: "main")
              NSApp.activate(ignoringOtherApps: true)
            }
            .controlSize(.small)
            Toggle("置于顶层", isOn: $pinnedToFront)
              .toggleStyle(.button)
              .controlSize(.small)
          }
          .padding(10)
          Divider()
          WorkspaceTabContentView(store: store, tab: tab)
        }
        .background(WindowLevelReader(pinnedToFront: pinnedToFront).frame(width: 0, height: 0))
      } else {
        ContentUnavailableView("标签页已关闭", systemImage: "xmark.square")
      }
    }
    .navigationTitle(tab.map(store.workspaceTabTitle) ?? "标签页")
    .onDisappear { store.restoreDetachedWorkspaceTab(tabID) }
  }
}

private struct WindowLevelReader: NSViewRepresentable {
  let pinnedToFront: Bool

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { view.window?.level = pinnedToFront ? .floating : .normal }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { view.window?.level = pinnedToFront ? .floating : .normal }
  }
}
