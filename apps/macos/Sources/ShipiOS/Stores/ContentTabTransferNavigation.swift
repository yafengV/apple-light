import Foundation

extension WorkspaceStore {
  /// Receiving a tab updates that task's layout even before its page is visited.
  /// Global browser selection follows only the task currently on screen.
  func recordReceivedWorkspaceTab(_ tab: WorkspaceContentTab) {
    guard tab.owner != currentWorkspaceTabOwner else { activateWorkspaceTab(tab.id); return }
    let place = workspaceTabPlacement(tab.id)
    var layout: WorkspaceTabLayout = library.workspaceTabLayouts[tab.owner] ?? WorkspaceTabLayout(tabs: [],
      showingInspector: false, showingTerminal: false, showingTabs: true, side: .left,
      reviewScope: library.gitPreferences.defaultReviewScope,
      contentLayoutMode: place == .left ? .full : .split)
    let scope = workspaceTabCloseScope(tab), ids = workspaceTabCloseIDs(scope)
    var controller = workspaceTabCloseControllers[scope] ?? .init()
    let mode = layout.contentLayoutMode ?? (layout.active == nil ? .split : .full)
    let actual = place == .bottom ? layout.bottom : mode == .full ? layout.active : layout.right
    if controller.selectedID == nil, let actual, ids.contains(actual) { controller.selectedID = actual }
    controller.select(tab.id, in: ids)
    workspaceTabCloseControllers[scope] = controller
    layout.tabs.removeAll { $0.id == tab.id }
    layout.tabs.append(savedWorkspaceTab(tab))
    switch place {
    case .left, .right:
      layout.contentLayoutMode = mode
      if mode == .full { layout.active = tab.id }
      else { layout.active = nil; layout.right = tab.id; layout.showingInspector = true }
      layout.focused = tab.id
    case .bottom: layout.bottom = tab.id; layout.showingTerminal = true; layout.focused = tab.id
    case .detached: break
    }
    library.workspaceTabLayouts[tab.owner] = layout
  }
}
