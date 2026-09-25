import Foundation

extension WorkspaceStore {
  var commandBrowserTabs: [CommandBrowserResult] {
    allCommandBrowserTabs.filter { workspaceTabPlacement($0.id) != .detached }
  }

  var allCommandBrowserTabs: [CommandBrowserResult] {
    workspaceTabs.compactMap { tab in
      guard let browserID = tab.browserID,
        let browser = workspace.browser.tabs.first(where: { $0.id == browserID }), !browser.closed else { return nil }
      let task = library.tasks.first(where: { $0.id == tab.owner })
      guard task != nil || tab.owner.hasPrefix("new:") else { return nil }
      return CommandBrowserResult(id: tab.id, owner: tab.owner, title: browser.title,
        pageTitle: browser.view.title ?? "", url: browser.committedURL?.absoluteString ?? "",
        ownerTitle: task?.title ?? "新任务")
    }
  }

  func canOpenCommandBrowserTab(_ result: CommandBrowserResult) -> Bool {
    guard !busy, commandBrowserTabs.contains(where: { $0.id == result.id && $0.owner == result.owner }) else { return false }
    if result.owner == currentWorkspaceTabOwner { return true }
    if let task = library.tasks.first(where: { $0.id == result.owner }) { return canSelectTask(task) }
    return result.owner.hasPrefix("new:") && (activeLocalRun == nil || commandBrowserDraftProject(result.owner) == currentProjectKey)
  }

  @discardableResult func openCommandBrowserTab(_ result: CommandBrowserResult) async -> Bool {
    guard canOpenCommandBrowserTab(result) else { return false }
    if result.owner != currentWorkspaceTabOwner {
      recordNavigation()
      if let previous = selectedTask, library.recordTaskVisit(previous.id) { saveLibrary() }
      if let task = library.tasks.first(where: { $0.id == result.owner }) {
        guard await openTaskScope(task.project),
          commandBrowserTabs.contains(where: { $0.id == result.id && $0.owner == result.owner }),
          let current = library.tasks.first(where: { $0.id == result.owner }) else { return false }
        applyTaskSelection(current)
      } else {
        guard await openTaskScope(commandBrowserDraftProject(result.owner)),
          commandBrowserTabs.contains(where: { $0.id == result.id && $0.owner == result.owner }) else { return false }
        newTask(recordHistory: false)
      }
    }
    guard let tab = workspaceTabs.first(where: { $0.id == result.id && $0.owner == currentWorkspaceTabOwner }),
      workspaceTabPlacement(tab.id) != .detached, let browserID = tab.browserID else { return false }
    activateWorkspaceTab(tab.id)
    workspace.browser.select(browserID)
    return true
  }

  private func commandBrowserDraftProject(_ owner: String) -> String {
    owner == "new:none" ? "" : String(owner.dropFirst(4))
  }
}
