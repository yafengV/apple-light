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
  @Environment(\.dismiss) private var dismiss
  @State private var pinnedToFront = false
  @State private var focusingChat = false
  @State private var search = DetachedWindowSearch()

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
            Button("聚焦聊天", action: focusChat)
            .controlSize(.small)
            .disabled(focusingChat || !store.canFocusDetachedWorkspaceChat(tabID))
            Toggle("置于顶层", isOn: $pinnedToFront)
              .toggleStyle(.button)
              .controlSize(.small)
          }
          .padding(10)
          Divider()
          if case .review(let owner) = tab {
            DetachedReviewView(store: store, owner: owner, focusComposer: focusChat)
          } else if let browserID = tab.browserID {
            BrowserPanel(store: store, session: store.workspace.browser,
              context: browserContext(tab), showsTabStrip: false, tabID: browserID)
          } else {
            WorkspaceTabContentView(store: store, tab: tab)
          }
        }
        .background(WindowLevelReader(pinnedToFront: pinnedToFront).frame(width: 0, height: 0))
      } else {
        ContentUnavailableView("标签页已关闭", systemImage: "xmark.square")
      }
    }
    .disabled(search.mode != nil).allowsHitTesting(search.mode == nil).accessibilityHidden(search.mode != nil)
    .overlay { searchOverlay }
    .onChange(of: search.mode) { _, mode in if mode == nil { search.restoreFocus() } }
    .focusedSceneValue(\.searchDialogActive, search.mode != nil)
    .onChange(of: store.restoredDetachedWorkspaceTabIDs, initial: true) { _, _ in
      for route in store.takePendingDetachedWindowRoutes() { openWindow(value: route) }
    }
    .task(id: store.savedBrowserTab(tabID)) {
      guard store.savedBrowserTab(tabID) != nil else { return }
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      store.saveLibrary()
    }
    .focusedSceneValue(\.taskWindowCommands, commands)
    .background(TaskWindowCommandKeyboardBridge(commands: commands, shortcuts: store.shortcuts,
      blocked: store.restoringLibrary || search.mode != nil).frame(width: 0, height: 0))
    .navigationTitle(tab.map(store.workspaceTabTitle) ?? "标签页")
    .onDisappear { store.restoreDetachedWorkspaceTab(tabID) }
  }

  private var commands: TaskWindowCommandContext {
    search.commands(store: store, tabID: tabID, closeWindow: { dismiss() })
  }

  @ViewBuilder private var searchOverlay: some View {
    let context = search.context(store: store, tabID: tabID, closeWindow: { dismiss() },
      showMain: showMainWindow, showDetached: { openWindow(value: $0) })
    switch search.mode {
    case .commands: CommandPaletteView(store: store, context: context)
    case .tasks: TaskSearchView(store: store, context: context)
    case .files, nil: EmptyView()
    }
  }

  private func browserContext(_ tab: WorkspaceContentTab) -> BrowserPanelContext {
    BrowserPanelContext(taskID: tab.owner,
      canFocus: { search.mode == nil && !store.shuttingDown && store.workspaceTabPlacement(tabID) == .detached },
      newTab: { _ = commands.execute("browser-new") },
      closeTab: { store.closeBrowserTab($0); dismiss() },
      reopen: { openOwnerChat(command: "browser-reopen") },
      openSettings: {
        store.openSettings(.browser)
        showMainWindow()
      }, focusComposer: focusChat, independentFocus: true, canReopen: false)
  }

  private func showMainWindow() {
    openWindow(id: "main")
    DispatchQueue.main.async {
      if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
        if main.isMiniaturized { main.deminiaturize(nil) }
        main.makeKeyAndOrderFront(nil)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func focusChat() { openOwnerChat() }

  private func openOwnerChat(command: String? = nil) {
    guard !focusingChat else { return }
    focusingChat = true
    Task {
      defer { focusingChat = false }
      guard await store.focusDetachedWorkspaceChat(tabID) else { return }
      if let command { store.executeCommand(command) }
      showMainWindow()
    }
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
