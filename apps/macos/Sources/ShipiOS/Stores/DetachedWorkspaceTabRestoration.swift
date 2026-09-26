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
    if restoringLibrary || libraryLoading { return .loading }
    if !libraryLoaded {
      return libraryReadError.map(DetachedWorkspaceTabRestoration.failed) ?? .loading
    }
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
    guard owner.hasPrefix("new:") || library.tasks.contains(where: { $0.id == owner }) else { return .close }
    if let live = workspaceTabs.first(where: { $0.id == route.tabID }) {
      return live.owner == owner && workspaceTabPlacement(live.id) == .detached ? .ready(owner) : .close
    }
    guard let saved = library.workspaceTabLayouts[owner]?.tabs.first(where: { $0.id == route.tabID }),
      saved.placement == .detached else { return .close }
    switch saved.kind {
    case .review:
      guard saved.id == WorkspaceContentTab.review(owner: owner).id,
        workspaceTabProject(owner: owner) != nil else { return .close }
    case .plan:
      guard saved.id.hasPrefix("plan:") else { return .close }
      let runID = String(saved.id.dropFirst(5))
      guard library.tasks.first(where: { $0.id == owner })?.runIDs.contains(runID) == true,
        taskWindowRuns(owner).first(where: { $0.id == runID })?.codexPlanDocument != nil else { return .close }
    case .browser:
      guard saved.id.hasPrefix("browser:"), UUID(uuidString: String(saved.id.dropFirst(8))) != nil else { return .close }
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
