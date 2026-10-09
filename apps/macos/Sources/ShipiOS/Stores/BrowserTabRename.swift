import Foundation

extension WorkspaceStore {
  var browserRenameActive: Bool { workspace.browser.renameRequest != nil }

  @discardableResult func beginWorkspaceBrowserRename(_ tabID: String) -> Bool {
    guard destination == .workspace, commandEnabled("browser"), presentedOverlay == nil,
      !showingModelPicker, !showingBranchPicker, !showingTaskStatus,
      !workspace.showingCommitPush, !workspace.showingPullRequest, !workspace.showingManagedBranchSetup,
      let tab = workspaceTabs.first(where: { $0.id == tabID && $0.owner == currentWorkspaceTabOwner }),
      [.left, .right].contains(workspaceTabPlacement(tabID)), let id = tab.browserID else { return false }
    return workspace.browser.beginRename(id)
  }

  func workspaceBrowserRenamed(_ id: UUID) {
    guard let page = workspace.browser.tabs.first(where: { $0.id == id }),
      let tab = workspaceTabs.first(where: { $0.browserID == id }) else { return }
    for index in library.pinnedContentTabs.indices {
      let pin = library.pinnedContentTabs[index]
      guard pin.sourceWindowID == nil, pin.owner == tab.owner, pin.sourceTabID == tab.id else { continue }
      library.pinnedContentTabs[index].browserCustomTitle = page.customTitle
      library.pinnedContentTabs[index].title = page.title
    }
    saveLibrary()
  }
}
