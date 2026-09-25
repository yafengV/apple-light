import Foundation

extension WorkspaceStore {
  var workspaceTabLayoutSnapshot: WorkspaceTabLayout {
    WorkspaceTabLayout(tabs: visibleWorkspaceContentTabs.map { tab in
      let browser = tab.browserID.flatMap { id in workspace.browser.tabs.first { $0.id == id } }
      return SavedWorkspaceTab(id: tab.id,
        kind: tab.browserID != nil ? .browser : tab.terminalID != nil ? .terminal : .review,
        placement: workspaceTabPlacement(tab.id), address: browser?.address,
        committedURL: browser?.committedURL?.absoluteString)
    }, active: activeWorkspaceTabID, right: activeRightWorkspaceTabID,
      bottom: activeBottomWorkspaceTabID, focused: focusedWorkspaceTabID,
      showingInspector: showingInspector, showingTerminal: showingTerminal,
      showingTabs: showingWorkspaceTabs, side: workspaceContentPaneSide, reviewScope: workspace.reviewScope)
  }

  func captureWorkspaceTabLayout() {
    guard libraryLoaded, !shuttingDown, !restoringWorkspaceTabLayout,
      workspaceLayoutActiveOwner == currentWorkspaceTabOwner else { return }
    guard currentWorkspaceTabOwner.hasPrefix("new:") || library.tasks.contains(where: { $0.id == currentWorkspaceTabOwner }) else { return }
    library.workspaceTabLayouts[currentWorkspaceTabOwner] = workspaceTabLayoutSnapshot
  }

  func restoreWorkspaceTabLayout() {
    let owner = currentWorkspaceTabOwner
    guard libraryLoaded, scopeLoaded, project == nil || connected,
      !restoringWorkspaceTabLayout, workspaceLayoutActiveOwner != owner else { return }
    workspaceLayoutActiveOwner = owner
    guard let layout = library.workspaceTabLayouts[owner] else {
      restoredWorkspaceTabOwners.insert(owner)
      return
    }
    restoringWorkspaceTabLayout = true
    defer { restoringWorkspaceTabLayout = false }
    if restoredWorkspaceTabOwners.insert(owner).inserted {
      var seen = Set<String>()
      for saved in layout.tabs where seen.insert(saved.id).inserted {
        _ = materializeWorkspaceTab(saved, owner: owner)
      }
    }
    func selected(_ id: String?, in placement: WorkspaceTabPlacement) -> String? {
      guard let id, visibleWorkspaceContentTabs(in: placement).contains(where: { $0.id == id }) else { return nil }
      return id
    }
    // Select the browser without moving keyboard focus during workspace loading.
    if let id = [layout.focused, layout.active, layout.right].compactMap({ $0 }).first(where: { id in
      visibleWorkspaceContentTabs.contains { $0.id == id && $0.browserID != nil }
    }), let browserID = visibleWorkspaceContentTabs.first(where: { $0.id == id })?.browserID {
      workspace.browser.select(browserID, focus: false)
    }
    activeWorkspaceTabID = selected(layout.active, in: .left)
    activeRightWorkspaceTabID = selected(layout.right, in: .right)
    activeBottomWorkspaceTabID = selected(layout.bottom, in: .bottom)
    focusedWorkspaceTabID = visibleWorkspaceContentTabs.first { $0.id == layout.focused }?.id
    showingInspector = layout.showingInspector
    showingTerminal = layout.showingTerminal && !visibleWorkspaceContentTabs(in: .bottom).isEmpty
    showingWorkspaceTabs = layout.showingTabs
    workspaceContentPaneSide = layout.side
    workspace.reviewScope = layout.reviewScope
    restoredDetachedWorkspaceTabIDs = visibleWorkspaceContentTabs(in: .detached).map(\.id)
  }

  /// Creates only this owner’s resource; never changes the main selection or focus.
  @discardableResult func materializeWorkspaceTab(_ saved: SavedWorkspaceTab, owner: String) -> WorkspaceContentTab? {
    if let existing = workspaceTabs.first(where: { $0.id == saved.id }) {
      return existing.owner == owner ? existing : nil
    }
    let tab: WorkspaceContentTab
    switch saved.kind {
    case .browser:
      guard saved.id.hasPrefix("browser:"), let id = UUID(uuidString: String(saved.id.dropFirst(8))) else { return nil }
      reopeningWorkspaceTabOwner = owner
      let browser = workspace.browser.newTab(activate: false, id: id)
      reopeningWorkspaceTabOwner = nil
      if let raw = saved.committedURL, let url = URL(string: raw), BrowserAddress.permits(url) {
        browser.address = raw
        browser.navigate()
      }
      browser.address = saved.address ?? saved.committedURL ?? ""
      browser.editingAddress = saved.address != nil && saved.address != saved.committedURL
      tab = .browser(id, owner: owner)
    case .review:
      guard workspaceTabProject(owner: owner) != nil, saved.id == WorkspaceContentTab.review(owner: owner).id else { return nil }
      tab = .review(owner: owner)
      workspaceTabs.append(tab)
    case .terminal:
      guard let root = workspaceTabProject(owner: owner),
        saved.id.hasPrefix("terminal:"), let id = UUID(uuidString: String(saved.id.dropFirst(9))) else { return nil }
      _ = workspace.terminals.newSession(for: TerminalScope(root: root, conversation: owner), id: id)
      tab = .terminal(id, owner: owner)
      workspaceTabs.append(tab)
    }
    workspaceTabPlacements[tab.id] = saved.placement == .bottom && tab.terminalID == nil ? .left : saved.placement
    return tab
  }
}
