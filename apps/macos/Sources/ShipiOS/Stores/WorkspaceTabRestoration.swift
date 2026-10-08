import Foundation

extension WorkspaceStore {
  var workspaceTabLayoutSnapshot: WorkspaceTabLayout {
    WorkspaceTabLayout(tabs: visibleWorkspaceContentTabs.map(savedWorkspaceTab),
      active: activeWorkspaceTabID, right: activeRightWorkspaceTabID,
      bottom: activeBottomWorkspaceTabID, focused: focusedWorkspaceTabID,
      showingInspector: showingInspector, showingTerminal: showingTerminal,
      showingTabs: showingWorkspaceTabs, side: workspaceContentPaneSide, reviewScope: workspace.selectedReviewScope,
      reviewRepository: workspace.selectedReviewRepository, contentLayoutMode: effectiveWorkspaceContentLayoutMode)
  }

  func savedWorkspaceTab(_ tab: WorkspaceContentTab) -> SavedWorkspaceTab {
    let browser = tab.browserID.flatMap { id in workspace.browser.tabs.first { $0.id == id } }
    let splitFraction = tab.terminalID.flatMap { id -> Double? in
      guard let scope = terminalScope(for: tab), workspace.terminals.splitSession(for: id, in: scope) != nil else { return nil }
      return workspace.terminals.splitFraction(for: id, in: scope)
    }
    return SavedWorkspaceTab(id: tab.id,
      kind: tab.kind,
      placement: workspaceTabPlacement(tab.id), address: browser?.address,
      committedURL: tab.pullRequestURL ?? browser?.committedURL?.absoluteString,
      filePath: { if case .file(let path, _) = tab { return path }; return nil }(),
      terminalSplitFraction: splitFraction,
      watchAutomationID: tab.watchAutomationID, watchTaskID: tab.watchTaskID)
  }

  func captureWorkspaceTabLayout() {
    guard libraryLoaded, !shuttingDown, !restoringWorkspaceTabLayout else { return }
    captureBackgroundBrowserTabs()
    guard workspaceLayoutActiveOwner == currentWorkspaceTabOwner else { return }
    guard automationsLoaded || library.workspaceTabLayouts[currentWorkspaceTabOwner]?.tabs.contains(where: {
      $0.kind == .pullRequestWatch
    }) != true else { return }
    guard workspaceDraftIdentity(owner: currentWorkspaceTabOwner) != nil || library.tasks.contains(where: { $0.id == currentWorkspaceTabOwner }) else { return }
    library.workspaceTabLayouts[currentWorkspaceTabOwner] = workspaceTabLayoutSnapshot
  }

  func restoreWorkspaceTabLayout() {
    let owner = currentWorkspaceTabOwner
    guard libraryLoaded, scopeLoaded, project == nil || connected,
      !restoringWorkspaceTabLayout, workspaceLayoutActiveOwner != owner else { return }
    if !automationsLoaded,
      library.workspaceTabLayouts[owner]?.tabs.contains(where: { $0.kind == .pullRequestWatch }) == true { return }
    workspaceLayoutActiveOwner = owner
    workspaceContentLayoutMode = nil
    guard let layout = library.workspaceTabLayouts[owner] else {
      restoredWorkspaceTabOwners.insert(owner)
      return
    }
    restoringWorkspaceTabLayout = true
    defer { restoringWorkspaceTabLayout = false }
    if restoredWorkspaceTabOwners.insert(owner).inserted {
      var seen = Set<String>()
      var restored: [WorkspaceContentTab] = []
      for saved in layout.tabs where seen.insert(saved.id).inserted {
        if let tab = materializeWorkspaceTab(saved, owner: owner) { restored.append(tab) }
      }
      let restoredIDs = Set(restored.map(\.id))
      var ordered = (restored + visibleWorkspaceContentTabs.filter { !restoredIDs.contains($0.id) }).makeIterator()
      for index in workspaceTabs.indices where workspaceTabs[index].owner == owner {
        if let tab = ordered.next() { workspaceTabs[index] = tab }
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
    workspaceContentLayoutMode = layout.contentLayoutMode ?? (selected(layout.active, in: .left) == nil ? .split : .full)
    func primary(_ id: String?) -> String? { workspacePrimaryContentTabs.first { $0.id == id }?.id }
    activeWorkspaceTabID = effectiveWorkspaceContentLayoutMode == .full ? primary(layout.active) : nil
    activeRightWorkspaceTabID = primary(layout.right) ?? (effectiveWorkspaceContentLayoutMode == .split ? primary(layout.active) : nil)
    activeBottomWorkspaceTabID = selected(layout.bottom, in: .bottom)
    focusedWorkspaceTabID = visibleWorkspaceContentTabs.first { $0.id == layout.focused }?.id
    showingInspector = layout.showingInspector
    showingTerminal = layout.showingTerminal && !visibleWorkspaceContentTabs(in: .bottom).isEmpty
    showingWorkspaceTabs = layout.showingTabs
    workspaceContentPaneSide = layout.side
    workspace.selectedReviewScope = layout.reviewScope
    workspace.restoreReviewRepository(layout.reviewRepository)
    restoredDetachedWorkspaceTabIDs = visibleWorkspaceContentTabs(in: .detached).map(\.id)
  }

  /// Creates only this owner’s resource; never changes the main selection or focus.
  @discardableResult func materializeWorkspaceTab(_ saved: SavedWorkspaceTab, owner: String) -> WorkspaceContentTab? {
    if let existing = workspaceTabs.first(where: { $0.id == saved.id }) {
      if existing.kind == .pullRequestWatch {
        guard existing.watchAutomationID == saved.watchAutomationID,
          existing.watchTaskID == saved.watchTaskID, pullRequestWatchContent(existing) != nil else { return nil }
      }
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
    case .file:
      guard let root = workspaceTabProject(owner: owner), let path = saved.filePath,
        path.isEmpty || (try? WorkspaceFileScope.location(path,
          roots: [root] + additionalWorkspaceFolders(for: root))) != nil else { return nil }
      let candidate = WorkspaceContentTab.file(path, owner: owner)
      guard candidate.id == saved.id else { return nil }
      tab = candidate
      workspaceTabs.append(tab)
    case .review:
      guard workspaceTabProject(owner: owner) != nil, saved.id == WorkspaceContentTab.review(owner: owner).id else { return nil }
      tab = .review(owner: owner)
      workspaceTabs.append(tab)
    case .plan:
      guard saved.id.hasPrefix("plan:") else { return nil }
      let runID = String(saved.id.dropFirst(5))
      guard !runID.isEmpty,
        library.tasks.first(where: { $0.id == owner })?.runIDs.contains(runID) == true,
        taskWindowRuns(owner).first(where: { $0.id == runID })?.codexPlanDocument != nil else { return nil }
      tab = .plan(runID, owner: owner)
      workspaceTabs.append(tab)
    case .sources:
      guard library.tasks.contains(where: { $0.id == owner }),
        saved.id == WorkspaceContentTab.sources(owner: owner).id else { return nil }
      tab = .sources(owner: owner)
      workspaceTabs.append(tab)
    case .pullRequest:
      let candidate = WorkspaceContentTab.pullRequest(saved.committedURL ?? "", owner: owner)
      guard saved.id == candidate.id, pullRequestContent(candidate) != nil else { return nil }
      tab = candidate
      workspaceTabs.append(tab)
    case .pullRequestWatch:
      guard let id = saved.watchAutomationID, let target = saved.watchTaskID else { return nil }
      let candidate = WorkspaceContentTab.pullRequestWatch(id, task: target, owner: owner)
      guard saved.id == candidate.id, pullRequestWatchContent(candidate) != nil else { return nil }
      tab = candidate
      workspaceTabs.append(tab)
    case .subagents:
      guard saved.id == WorkspaceContentTab.subagents(owner: owner).id,
        library.tasks.contains(where: { $0.id == owner }) else { return nil }
      tab = .subagents(owner: owner); workspaceTabs.append(tab)
    case .backgroundTerminal:
      guard let id = WorkspaceContentTab.backgroundTerminalID(saved.id, owner: owner),
        backgroundTerminalDocument(id, taskID: owner) != nil else { return nil }
      tab = .backgroundTerminal(id, owner: owner)
      workspaceTabs.append(tab)
    case .terminal:
      guard let root = workspaceTabProject(owner: owner),
        saved.id.hasPrefix("terminal:"), let id = UUID(uuidString: String(saved.id.dropFirst(9))) else { return nil }
      let scope = TerminalScope(root: root, conversation: owner)
      _ = workspace.terminals.newSession(for: scope, id: id)
      if let fraction = saved.terminalSplitFraction {
        _ = workspace.terminals.split(id, in: scope)
        workspace.terminals.setSplitFraction(fraction, for: id, in: scope)
      }
      tab = .terminal(id, owner: owner)
      workspaceTabs.append(tab)
    }
    workspaceTabPlacements[tab.id] = saved.placement == .bottom && tab.terminalID == nil ? .left : saved.placement
    return tab
  }
}
