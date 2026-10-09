import Foundation

@MainActor struct PinnedBrowserRenameRequest: Identifiable {
  let id = UUID()
  let pin: PinnedWorkspaceTab
  let session: BrowserSession
  let page: BrowserTab
  let initialTitle: String
  let defaultTitle: String
  let sourceProject: String?
}

extension WorkspaceStore {
  var mainRenameDialogActive: Bool { renameTaskID != nil || pinnedBrowserRenameRequest != nil }

  /// Resolving an action must never reveal a chat, restore a cold source or move a page.
  private func pinnedBrowserSource(_ pin: PinnedWorkspaceTab) -> (BrowserSession, BrowserTab)? {
    guard pin.kind == .browser,
      library.tasks.contains(where: { $0.id == pin.owner }) || workspaceDraftIdentity(owner: pin.owner) != nil else { return nil }
    let session: BrowserSession
    if let windowID = pin.sourceWindowID {
      guard let resources = taskWindowResources.allObjects.first(where: { $0.id == windowID }),
        resources.contains(pin), let tabs = resources.tasks[pin.owner],
        let tab = tabs.tabs.first(where: { $0.id == pin.sourceTabID }),
        tabs.draggingTabID != pin.sourceTabID,
        [.left, .right].contains(tabs.placement(tab.id)) else { return nil }
      session = tabs.browser.session
    } else {
      guard let tab = workspaceTabs.first(where: { $0.id == pin.sourceTabID && $0.owner == pin.owner }),
        draggingWorkspaceTabID != pin.sourceTabID,
        tab.kind == .browser, [.left, .right].contains(workspaceTabPlacement(tab.id)) else { return nil }
      session = workspace.browser
    }
    guard pin.sourceTabID.hasPrefix("browser:"),
      let id = UUID(uuidString: String(pin.sourceTabID.dropFirst(8))),
      let page = session.tabs.first(where: { $0.id == id && !$0.closed }) else { return nil }
    return (session, page)
  }

  func canRenamePinnedBrowser(_ pinID: String) -> Bool {
    guard let pin = library.pinnedContentTabs.first(where: { $0.id == pinID }) else { return false }
    return pinnedBrowserSource(pin) != nil
  }

  @discardableResult func beginPinnedBrowserRename(_ pinID: String) -> Bool {
    guard destination == .workspace, !mainRenameDialogActive,
      !libraryRecoveryBlocksInteraction, presentedOverlay == nil, !hasSettingsConfirmation,
      editingProject == nil, renameProjectPath == nil, sidebarGroupEditor == nil,
      !showingModelPicker, !showingBranchPicker, !showingTaskStatus,
      !workspace.showingCommitPush, !workspace.showingPullRequest, !workspace.showingManagedBranchSetup,
      let pin = library.pinnedContentTabs.first(where: { $0.id == pinID }),
      let (session, page) = pinnedBrowserSource(pin) else { return false }
    pinnedBrowserRenameRequest = PinnedBrowserRenameRequest(pin: pin, session: session, page: page,
      initialTitle: page.customTitle ?? "", defaultTitle: page.pageTitle,
      sourceProject: workspaceTabProject(owner: pin.owner)?.path)
    return true
  }

  @discardableResult func savePinnedBrowserRename(_ request: PinnedBrowserRenameRequest, title: String) -> Bool {
    guard pinnedBrowserRenameRequest?.id == request.id,
      let pin = library.pinnedContentTabs.first(where: { $0.id == request.pin.id }),
      pin.owner == request.pin.owner, pin.sourceTabID == request.pin.sourceTabID,
      pin.sourceWindowID == request.pin.sourceWindowID, pin.kind == request.pin.kind,
      workspaceTabProject(owner: pin.owner)?.path == request.sourceProject,
      let (session, page) = pinnedBrowserSource(pin), session === request.session,
      page === request.page else { return false }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // The dialog's unchanged initial value cannot overwrite another window's rename.
    guard trimmed != request.initialTitle.trimmingCharacters(in: .whitespacesAndNewlines) else { return true }
    return session.renameTab(page, title: trimmed.isEmpty ? nil : trimmed)
  }

  func closePinnedBrowserRename(_ request: PinnedBrowserRenameRequest, restoreFocus: Bool = true) {
    guard pinnedBrowserRenameRequest?.id == request.id else { return }
    pinnedBrowserRenameRequest = nil
    guard restoreFocus, library.pinnedContentTabs.contains(where: { $0.id == request.pin.id }) else { return }
    pinnedBrowserRenameReturnPinID = request.pin.id
    pinnedBrowserRenameReturnFocus = UUID()
  }

  func cancelPinnedBrowserRename(_ pinID: String? = nil) {
    guard let request = pinnedBrowserRenameRequest, pinID == nil || request.pin.id == pinID else { return }
    closePinnedBrowserRename(request, restoreFocus: false)
  }
}
