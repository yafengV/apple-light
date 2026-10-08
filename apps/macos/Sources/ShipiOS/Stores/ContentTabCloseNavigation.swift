import Foundation

extension WorkspaceStore {
  func workspaceTabCloseScope(_ tab: WorkspaceContentTab) -> ContentTabCloseScope {
    ContentTabCloseScope(owner: tab.owner, panel: .init(workspaceTabPlacement(tab.id), id: tab.id))
  }
  func workspaceTabCloseIDs(_ scope: ContentTabCloseScope) -> [String] {
    workspaceTabs.filter { workspaceTabCloseScope($0) == scope }.map(\.id)
  }
  func recordWorkspaceTabSelection(_ tab: WorkspaceContentTab) {
    guard !restoringWorkspaceTabLayout else { return }
    let scope = workspaceTabCloseScope(tab)
    if workspaceTabCloseControllers[scope]?.selectedID == nil {
      let current = scope.panel == .bottom ? activeBottomWorkspaceTabID
        : scope.panel == .primary ? (effectiveWorkspaceContentLayoutMode == .full ? activeWorkspaceTabID : activeRightWorkspaceTabID) : nil
      if let current, workspaceTabCloseIDs(scope).contains(current) {
        workspaceTabCloseControllers[scope, default: .init()].selectedID = current
      }
    }
    workspaceTabCloseControllers[scope, default: .init()].select(tab.id, in: workspaceTabCloseIDs(scope))
  }
  func recordWorkspaceTabMoved(_ tab: WorkspaceContentTab) {
    let scope = workspaceTabCloseScope(tab)
    workspaceTabCloseControllers[scope, default: .init()].history.moved(tab.id)
  }
  func recordWorkspaceTabOpened(_ tab: WorkspaceContentTab, by opener: WorkspaceContentTab, background: Bool) {
    let scope = workspaceTabCloseScope(tab)
    guard scope == workspaceTabCloseScope(opener), scope.panel == .primary || scope.panel == .bottom else { return }
    workspaceTabCloseControllers[scope, default: .init()].history.opened(tab.id, by: opener.id, background: background)
  }

  /// Called before deleting presentation metadata so mixed-kind order and pane
  /// ownership are still available. BrowserSession never chooses a second fallback.
  func workspaceTabDidDisappear(_ tab: WorkspaceContentTab, transferring: Bool = false) {
    let id = tab.id, scope = workspaceTabCloseScope(tab), ids = workspaceTabCloseIDs(scope)
    let currentOwner = tab.owner == currentWorkspaceTabOwner
    let mainSelected = currentOwner && activeWorkspaceTabID == id
    let rightSelected = currentOwner && activeRightWorkspaceTabID == id
    let bottomSelected = currentOwner && activeBottomWorkspaceTabID == id
    let wasFocused = currentOwner && focusedWorkspaceContentTab?.id == id
    var controller = workspaceTabCloseControllers[scope] ?? .init()
    let actual: String?
    if currentOwner {
      actual = scope.panel == .bottom ? activeBottomWorkspaceTabID
        : scope.panel == .primary ? (effectiveWorkspaceContentLayoutMode == .full ? activeWorkspaceTabID : activeRightWorkspaceTabID) : nil
    } else {
      let layout = library.workspaceTabLayouts[tab.owner]
      let full = layout?.contentLayoutMode == .full || (layout?.contentLayoutMode == nil && layout?.active != nil)
      actual = scope.panel == .bottom ? layout?.bottom : scope.panel == .primary ? (full ? layout?.active : layout?.right) : nil
    }
    if let actual { controller.select(actual, in: ids) }
    let wasSelected = controller.selectedID == id
    let next = transferring ? controller.transfer(id, in: ids) : controller.close(id, in: ids)
    workspaceTabCloseControllers[scope] = controller
    pendingWorkspaceTabCloses[id] = nil
    workspaceTabs.removeAll { $0.id == id }
    if draggingWorkspaceTabID == id { endWorkspaceTabDrag() }
    workspaceTabPlacements[id] = nil

    if currentOwner {
      if mainSelected { activeWorkspaceTabID = next }
      if rightSelected { activeRightWorkspaceTabID = effectiveWorkspaceContentLayoutMode == .split ? next : nil }
      if bottomSelected { activeBottomWorkspaceTabID = next }
      if lastWorkspaceContentTabID == id { lastWorkspaceContentTabID = next }
      if focusedWorkspaceTabID == id { focusedWorkspaceTabID = wasFocused ? next : nil }
      if scope.panel == .primary, workspacePrimaryContentTabs.isEmpty,
        effectiveWorkspaceContentLayoutMode == .split { showingInspector = false }
      if scope.panel == .bottom, visibleWorkspaceContentTabs(in: .bottom).isEmpty { showingTerminal = false }
      let restoreFocus = wasFocused && !shuttingDown && destination == .workspace && presentedOverlay == nil
        && !hasSettingsConfirmation && !showingModelPicker && !showingBranchPicker
      if wasSelected, let replacement = visibleWorkspaceContentTabs.first(where: { $0.id == next }) {
        if let browserID = replacement.browserID {
          synchronizingWorkspaceBrowserSelection = true
          workspace.browser.select(browserID, focus: restoreFocus)
          synchronizingWorkspaceBrowserSelection = false
        } else if restoreFocus, let terminalID = replacement.terminalID { focusTerminal(terminalID) }
        else if restoreFocus, replacement.kind == .file { fileTabWorkspace(replacement).fileFocusRequest = UUID() }
      } else if restoreFocus, activeWorkspaceContentTab == nil { focusComposer = UUID() }
    } else if var layout = library.workspaceTabLayouts[tab.owner] {
      layout.tabs.removeAll { $0.id == id }
      if layout.active == id { layout.active = next }
      if layout.right == id { layout.right = next }
      if layout.bottom == id { layout.bottom = next }
      if layout.focused == id { layout.focused = next }
      library.workspaceTabLayouts[tab.owner] = layout
    }
  }
}
