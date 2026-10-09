import Foundation

extension WorkspaceStore {
  func workspaceDraftIdentity(owner: String) -> WorkspaceDraftIdentity? {
    let projects = Set(library.projectScopePaths + library.projects
      + Array(library.projectPrimaryFolders.keys) + Array(library.projectPrimaryFolders.values)
      + library.tasks.map(\.project) + (project.map { [$0.path] } ?? []))
    return WorkspaceDraftIdentity(owner: owner, knownProjects: projects.filter { $0.hasPrefix("/") })
  }

  func workspaceDraftProject(owner: String) -> String? {
    workspaceDraftIdentity(owner: owner).map { library.primaryFolder(for: $0.projectKey) }
  }

  /// Select an existing unsent draft. Creating a new draft would erase its nonce
  /// and strand its content, so all content return routes share this operation.
  @discardableResult func selectWorkspaceDraft(_ owner: String, recordHistory: Bool = true,
    revealingContentTabID: String? = nil,
    stillValid: () -> Bool = { true }) async -> Bool {
    guard libraryLoaded, !Task.isCancelled, !busy, !shuttingDown,
      let identity = workspaceDraftIdentity(owner: owner),
      let root = workspaceDraftProject(owner: owner),
      draftContentTargetAvailable(revealingContentTabID, owner: owner),
      activeLocalRun == nil || root == currentProjectKey, stillValid() else { return false }
    let origin = currentTaskLocation
    let previous = selectedTask?.id
    guard await openTaskScope(root, loadsDetails: false, stillValid: stillValid), !Task.isCancelled, !shuttingDown, stillValid(),
      workspaceDraftIdentity(owner: owner) == identity,
      draftContentTargetAvailable(revealingContentTabID, owner: owner),
      workspaceDraftProject(owner: owner) == root else { return false }
    if recordHistory {
      recordNavigation(origin)
      if let previous { library.recordTaskVisit(previous) }
    }
    return applyWorkspaceDraftSelection(identity, recordHistory: false, revealingContentTabID: revealingContentTabID)
  }

  @discardableResult func applyWorkspaceDraftSelection(_ identity: WorkspaceDraftIdentity,
    recordHistory: Bool, revealingContentTabID: String? = nil) -> Bool {
    guard identity.projectKey == (project == nil ? "" : currentDraftProjectKey),
      draftContentTargetAvailable(revealingContentTabID, owner: identity.owner),
      library.primaryFolder(for: identity.projectKey) == currentProjectKey else { return false }
    captureWorkspaceTabLayout()
    workspaceLayoutActiveOwner = nil
    if recordHistory { recordNavigation() }
    library.linkedNewTaskDraftIDs[identity.projectKey] = identity.linkID
    destination = .workspace
    dismissCodeReviewMode()
    selection = nil
    workspaceContentLayoutMode = nil
    activeWorkspaceTabID = nil
    activeRightWorkspaceTabID = nil
    activeBottomWorkspaceTabID = nil
    focusedWorkspaceTabID = nil
    events = []; logText = ""
    showingArchived = false
    chatMode = .standard
    pendingGoal = nil
    restoreWorkspaceTabLayout()
    // A content reveal must not select Chat first: that selection deliberately
    // discards the draft's sole empty full-view browser.
    if let revealingContentTabID { activateWorkspaceTab(revealingContentTabID) }
    else { activateChatTab() }
    rememberProjectSelection()
    saveLibrary()
    return true
  }

  private func draftContentTargetAvailable(_ id: String?, owner: String) -> Bool {
    guard let id else { return true }
    guard let tab = workspaceTabs.first(where: { $0.id == id && $0.owner == owner }),
      [.left, .right].contains(workspaceTabPlacement(id)) else { return false }
    if let browserID = tab.browserID {
      return workspace.browser.tabs.contains { $0.id == browserID && !$0.closed }
    }
    return true
  }
}
