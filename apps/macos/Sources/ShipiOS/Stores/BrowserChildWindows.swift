import WebKit

extension WorkspaceStore {
  /// Both WebKit popups and app-level new-page actions retain their origin.
  @discardableResult func newBrowserChild(from sourceID: UUID, configuration: WKWebViewConfiguration? = nil) -> BrowserTab? {
    guard !shuttingDown,
      let source = workspaceTabs.first(where: { $0.browserID == sourceID }),
      workspace.browser.tabs.contains(where: { $0.id == sourceID && !$0.closed }),
      source.owner.hasPrefix("new:") || library.tasks.contains(where: { $0.id == source.owner }) else { return nil }
    let placement = workspaceTabPlacement(source.id)
    reopeningWorkspaceTabOwner = source.owner
    let page = workspace.browser.newTab(configuration: configuration, activate: false)
    reopeningWorkspaceTabOwner = nil
    let id = WorkspaceContentTab.browser(page.id, owner: source.owner).id
    workspaceTabPlacements[id] = placement
    if let index = workspaceTabs.firstIndex(where: { $0.id == source.id }),
      let childIndex = workspaceTabs.firstIndex(where: { $0.id == id }) {
      let child = workspaceTabs.remove(at: childIndex)
      workspaceTabs.insert(child, at: index + 1)
      recordWorkspaceTabOpened(child, by: source, background: source.owner != currentWorkspaceTabOwner)
    }
    if source.owner != currentWorkspaceTabOwner {
      var layout = library.workspaceTabLayouts[source.owner] ?? WorkspaceTabLayout(tabs: [],
        showingInspector: false, showingTerminal: false, showingTabs: true, side: .left,
        reviewScope: library.gitPreferences.defaultReviewScope)
      if let saved = savedBrowserTab(id) {
        layout.tabs.removeAll { $0.id == id }
        let insertion = layout.tabs.firstIndex(where: { $0.id == source.id }).map { $0 + 1 } ?? layout.tabs.count
        layout.tabs.insert(saved, at: insertion)
      }
      library.workspaceTabLayouts[source.owner] = layout
    }
    if placement == .detached {
      restoredDetachedWorkspaceTabIDs.append(id)
      workspace.browser.focusAddress(tabID: page.id)
    } else if source.owner == currentWorkspaceTabOwner {
      activateWorkspaceTab(id)
    }
    saveLibrary()
    return page
  }

  func savedBrowserTab(_ id: String) -> SavedWorkspaceTab? {
    guard let tab = workspaceTabs.first(where: { $0.id == id }), let browserID = tab.browserID,
      let page = workspace.browser.tabs.first(where: { $0.id == browserID }) else { return nil }
    return SavedWorkspaceTab(id: id, kind: .browser, placement: workspaceTabPlacement(id),
      address: page.address, committedURL: page.committedURL?.absoluteString)
  }

  func captureBackgroundBrowserTabs() {
    for tab in workspaceTabs where tab.owner != currentWorkspaceTabOwner && tab.browserID != nil {
      guard let saved = savedBrowserTab(tab.id),
        let index = library.workspaceTabLayouts[tab.owner]?.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
      library.workspaceTabLayouts[tab.owner]?.tabs[index] = saved
    }
  }

  /// Multiple window scenes observe the queue; only the first consumes it.
  func takePendingDetachedWindowRoutes() -> [WorkspaceTabWindowRoute] {
    let ids = restoredDetachedWorkspaceTabIDs
    restoredDetachedWorkspaceTabIDs = []
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }.compactMap(detachedWorkspaceTabRoute)
  }
}
