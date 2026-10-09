import Foundation

/// The toolbar excludes Chat, detached windows and the bottom panel.
struct WorkspaceLayoutMenu: Equatable {
  struct Entry: Equatable {
    let id: String
    let title: String
    let icon: String
    var enabled = true
  }
  enum Kind: String { case toggle, retained, newTab }
  enum Action: Equatable { case toggle, create(WorkspaceContentLayoutMode), select(String, WorkspaceContentLayoutMode) }
  let entries: [Entry]
  let contentVisible: Bool
  let home: Bool
  var scope = ""
  var kind: Kind { contentVisible ? .toggle : entries.isEmpty ? (home ? .newTab : .toggle) : .retained }
  var actions: [Action] {
    switch kind {
    case .toggle: return []
    case .newTab: return [.create(.split), .create(.full)]
    case .retained: return entries.filter(\.enabled).flatMap { [.select($0.id, .split), .select($0.id, .full)] }
    }
  }
  func accepts(_ action: Action) -> Bool { action == .toggle || actions.contains(action) }
}

/// Only popup interaction is transient; the window's existing tabs own layout and selection.
struct WorkspaceLayoutMenuInteraction {
  enum Origin { case hover, keyboard }
  private(set) var origin: Origin?
  private(set) var highlighted: WorkspaceLayoutMenu.Action?
  private(set) var closeDeadline: TimeInterval?
  mutating func open(_ origin: Origin) { self.origin = origin; highlighted = nil; closeDeadline = nil }
  mutating func dismiss() { origin = nil; highlighted = nil; closeDeadline = nil }
  mutating func enter() { closeDeadline = nil }
  mutating func leave(now: TimeInterval) { if origin == .hover { closeDeadline = now + 0.1 } }
  mutating func keyboard(_ menu: WorkspaceLayoutMenu, last: Bool = false) {
    origin = .keyboard; closeDeadline = nil; highlighted = last ? menu.actions.last : menu.actions.first
  }
  mutating func focus(_ action: WorkspaceLayoutMenu.Action) { origin = .keyboard; closeDeadline = nil; highlighted = action }
  func expired(now: TimeInterval) -> Bool { closeDeadline.map { now >= $0 } ?? false }
}

extension WorkspaceStore {
  var workspaceLayoutMenu: WorkspaceLayoutMenu {
    .init(entries: workspacePrimaryContentTabs.map { .init(id: $0.id, title: workspaceTabTitle($0), icon: $0.icon) },
      contentVisible: activeWorkspaceContentTab != nil || (showsWorkspaceInspector && activeRightWorkspaceContentTab != nil),
      home: selectedTask == nil, scope: currentWorkspaceTabOwner)
  }
  func performWorkspaceLayoutMenuAction(_ action: WorkspaceLayoutMenu.Action) {
    guard commandEnabled("browser"), workspaceLayoutMenu.accepts(action) else { return }
    switch action {
    case .toggle: toggleWorkspaceContentVisibility()
    case .create(let mode): newBrowserTab(in: mode == .full ? .left : .right)
    case .select(let id, let mode): moveWorkspaceTab(id, to: mode == .full ? .left : .right)
    }
  }
}

extension TaskWindowTabs {
  var layoutMenu: WorkspaceLayoutMenu {
    .init(entries: primaryContentTabs.map { .init(id: $0.id, title: title($0), icon: $0.icon) },
      contentVisible: !chatVisible || showsContentSidePanel, home: taskID.hasPrefix("new:"), scope: taskID)
  }
  func performLayoutMenuAction(_ action: WorkspaceLayoutMenu.Action) {
    guard layoutMenu.accepts(action) else { return }
    switch action {
    case .toggle: toggleContentVisibility()
    case .create(let mode): newBrowser(in: mode == .full ? .left : .right)
    case .select(let id, let mode): move(id, to: mode == .full ? .left : .right)
    }
  }
}
