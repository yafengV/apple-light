import Foundation

extension WorkspaceStore {
  /// Closing a detached window returns its existing content to its owner even
  /// while the main window is displaying another task. Quitting keeps it detached.
  func restoreDetachedWorkspaceTab(_ id: String) {
    guard !shuttingDown, let tab = workspaceTabs.first(where: { $0.id == id }),
      workspaceTabPlacement(id) == .detached else { return }
    if tab.owner == currentWorkspaceTabOwner {
      moveWorkspaceTab(id, to: .left)
    } else {
      workspaceTabPlacements[id] = .left
      if var layout = library.workspaceTabLayouts[tab.owner],
        let index = layout.tabs.firstIndex(where: { $0.id == id }) {
        layout.tabs[index].placement = .left
        if let browserID = tab.browserID,
          let page = workspace.browser.tabs.first(where: { $0.id == browserID }) {
          layout.tabs[index].address = page.address
          layout.tabs[index].committedURL = page.committedURL?.absoluteString
        }
        layout.active = id
        layout.focused = id
        if layout.right == id { layout.right = nil }
        if layout.bottom == id { layout.bottom = nil }
        library.workspaceTabLayouts[tab.owner] = layout
      }
    }
    restoredDetachedWorkspaceTabIDs.removeAll { $0 == id }
    saveLibrary()
  }

  func canFocusDetachedWorkspaceChat(_ id: String) -> Bool {
    guard !busy, !shuttingDown, workspaceTabPlacement(id) == .detached,
      let tab = workspaceTabs.first(where: { $0.id == id }) else { return false }
    if tab.owner == currentWorkspaceTabOwner { return true }
    if let task = library.tasks.first(where: { $0.id == tab.owner }) { return canSelectTask(task) }
    guard tab.owner.hasPrefix("new:") else { return false }
    let project = tab.owner == "new:none" ? "" : String(tab.owner.dropFirst(4))
    return activeLocalRun == nil || project == currentProjectKey
  }

  @discardableResult func focusDetachedWorkspaceChat(_ id: String) async -> Bool {
    guard canFocusDetachedWorkspaceChat(id),
      let tab = workspaceTabs.first(where: { $0.id == id }) else { return false }
    if tab.owner != currentWorkspaceTabOwner {
      recordNavigation()
      if let task = library.tasks.first(where: { $0.id == tab.owner }) {
        guard await openTaskScope(task.project), !shuttingDown,
          workspaceTabs.contains(tab), workspaceTabPlacement(id) == .detached,
          let current = library.tasks.first(where: { $0.id == tab.owner }) else { return false }
        applyTaskSelection(current)
      } else {
        let project = tab.owner == "new:none" ? "" : String(tab.owner.dropFirst(4))
        guard await openTaskScope(project), !shuttingDown,
          workspaceTabs.contains(tab), workspaceTabPlacement(id) == .detached else { return false }
        newTask(recordHistory: false)
      }
    }
    guard currentWorkspaceTabOwner == tab.owner else { return false }
    destination = .workspace
    activateChatTab()
    saveLibrary()
    return true
  }
}
