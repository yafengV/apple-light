import Foundation

extension WorkspaceStore {
  func pullRequestWatchContent(_ tab: WorkspaceContentTab) -> ShipAutomation? {
    guard case .pullRequestWatch(let id, let target, let owner) = tab,
      libraryLoaded, automationsLoaded,
      library.tasks.contains(where: { $0.id == owner && !$0.archived && !$0.isTransient }),
      library.tasks.contains(where: { $0.id == target && !$0.archived && !$0.isTransient }),
      let watch = automationPreferences.items.first(where: { $0.id == id && $0.taskID == target }),
      let url = watch.watchedPullRequest?.validatedURL,
      library.taskPullRequests[owner]?.contains(where: { $0.validatedURL == url }) == true else { return nil }
    return watch
  }

  @discardableResult func openPullRequestWatchProgress(_ watch: ShipAutomation,
    in placement: WorkspaceTabPlacement = .right) -> Bool {
    guard !restoringLibrary, !shuttingDown, placement == .left || placement == .right,
      let target = watch.taskID else { return false }
    let tab = WorkspaceContentTab.pullRequestWatch(watch.id, task: target, owner: currentWorkspaceTabOwner)
    guard pullRequestWatchContent(tab) != nil else { return false }
    if let index = workspaceTabs.firstIndex(where: { $0.id == tab.id }) {
      workspaceTabs[index] = tab
    } else {
      workspaceTabs.append(tab)
      workspaceTabPlacements[tab.id] = placement
    }
    activateWorkspaceTab(tab.id)
    return true
  }

  @discardableResult func openPullRequestWatchProgress(_ watch: ShipAutomation, owner: String,
    valid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
    guard valid(), let task = library.tasks.first(where: { $0.id == owner }), canSelectTask(task) else { return false }
    if currentProjectKey != task.project { guard await openTaskScope(task.project) else { return false } }
    guard !Task.isCancelled, valid(), let current = library.tasks.first(where: { $0.id == owner }),
      canSelectTask(current) else { return false }
    if currentWorkspaceTabOwner != owner { recordNavigation(); applyTaskSelection(current) }
    return openPullRequestWatchProgress(watch)
  }
}
