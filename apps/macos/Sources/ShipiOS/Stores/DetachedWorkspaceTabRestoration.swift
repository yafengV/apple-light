import Foundation

enum DetachedWorkspaceTabRestoration: Equatable {
  case loading, failed(String), ready(String), close
}

extension WorkspaceStore {
  func detachedWorkspaceTabRoute(_ id: String) -> WorkspaceTabWindowRoute? {
    guard let tab = workspaceTabs.first(where: { $0.id == id }),
      workspaceTabPlacement(id) == .detached else { return nil }
    return WorkspaceTabWindowRoute(tabID: id, owner: tab.owner, dataRoot: dataRoot)
  }

  func detachedWorkspaceTabRestoration(_ route: WorkspaceTabWindowRoute?) -> DetachedWorkspaceTabRestoration {
    if let root = route?.dataRoot, root != TaskWindowRoute.workspacePath(dataRoot) { return .close }
    if restoringLibrary || libraryLoading || modelConfigurationLoading { return .loading }
    if let restorationReadError { return .failed(restorationReadError) }
    if !libraryLoaded { return .loading }
    guard let route else { return .loading }
    let owner: String
    if let explicit = route.owner { owner = explicit }
    else {
      // Legacy routes can be migrated only when their owner is unambiguous.
      var owners = Set(workspaceTabs.filter { $0.id == route.tabID }.map(\.owner))
      for (key, layout) in library.workspaceTabLayouts where layout.tabs.contains(where: { $0.id == route.tabID }) {
        owners.insert(key)
      }
      guard owners.count == 1, let resolved = owners.first else { return .close }
      owner = resolved
    }
    guard workspaceDraftIdentity(owner: owner) != nil || library.tasks.contains(where: { $0.id == owner }) else { return .close }
    if let live = workspaceTabs.first(where: { $0.id == route.tabID }) {
      if live.kind == .pullRequestWatch {
        if !automationsLoaded { return .loading }
        guard pullRequestWatchContent(live) != nil else { return .close }
      }
      return live.owner == owner && workspaceTabPlacement(live.id) == .detached ? .ready(owner) : .close
    }
    guard let saved = library.workspaceTabLayouts[owner]?.tabs.first(where: { $0.id == route.tabID }),
      saved.placement == .detached else { return .close }
    switch saved.kind {
    case .file:
      guard let root = workspaceTabProject(owner: owner), let path = saved.filePath,
        saved.id == WorkspaceContentTab.file(path, owner: owner).id,
        path.isEmpty || (try? WorkspaceFileScope.location(path,
          roots: [root] + additionalWorkspaceFolders(for: root))) != nil else { return .close }
    case .review:
      guard saved.id == WorkspaceContentTab.review(owner: owner).id,
        workspaceTabProject(owner: owner) != nil else { return .close }
    case .plan:
      guard saved.id.hasPrefix("plan:") else { return .close }
      let runID = String(saved.id.dropFirst(5))
      guard library.tasks.first(where: { $0.id == owner })?.runIDs.contains(runID) == true,
        taskWindowRuns(owner).first(where: { $0.id == runID })?.codexPlanDocument != nil else { return .close }
    case .sources:
      guard saved.id == WorkspaceContentTab.sources(owner: owner).id,
        library.tasks.contains(where: { $0.id == owner }) else { return .close }
    case .pullRequest:
      let candidate = WorkspaceContentTab.pullRequest(saved.committedURL ?? "", owner: owner)
      guard saved.id == candidate.id, pullRequestContent(candidate) != nil else { return .close }
    case .pullRequestWatch:
      if !automationsLoaded { return .loading }
      guard let id = saved.watchAutomationID, let target = saved.watchTaskID else { return .close }
      let candidate = WorkspaceContentTab.pullRequestWatch(id, task: target, owner: owner)
      guard saved.id == candidate.id, pullRequestWatchContent(candidate) != nil else { return .close }
    case .browser:
      guard saved.id.hasPrefix("browser:"), UUID(uuidString: String(saved.id.dropFirst(8))) != nil else { return .close }
    case .subagents:
      guard saved.id == WorkspaceContentTab.subagents(owner: owner).id,
        library.tasks.contains(where: { $0.id == owner }) else { return .close }
    case .backgroundTerminal:
      guard let id = WorkspaceContentTab.backgroundTerminalID(saved.id, owner: owner),
        backgroundTerminalDocument(id, taskID: owner) != nil else { return .close }
    case .terminal:
      guard saved.id.hasPrefix("terminal:"), UUID(uuidString: String(saved.id.dropFirst(9))) != nil,
        workspaceTabProject(owner: owner) != nil else { return .close }
    }
    return .ready(owner)
  }

  @discardableResult func prepareDetachedWorkspaceTab(_ route: WorkspaceTabWindowRoute) -> WorkspaceTabWindowRoute? {
    guard !shuttingDown, case .ready(let owner) = detachedWorkspaceTabRestoration(route) else { return nil }
    if !workspaceTabs.contains(where: { $0.id == route.tabID }),
      let saved = library.workspaceTabLayouts[owner]?.tabs.first(where: { $0.id == route.tabID }) {
      guard materializeWorkspaceTab(saved, owner: owner) != nil else { return nil }
    }
    return detachedWorkspaceTabRoute(route.tabID)
  }
}
