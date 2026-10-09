import AppKit

@MainActor struct PinnedBrowserActionContext {
  let pin: PinnedWorkspaceTab
  let session: BrowserSession
  let page: BrowserTab
  let project: String?
  let placement: WorkspaceTabPlacement
  let generation: UUID
  let actions: [PinnedBrowserAction]
}

enum PinnedBrowserAction: String, CaseIterable {
  case reload = "reload-browser-tab"
  case duplicate = "duplicate-browser-tab"
  case copyURL = "copy-browser-tab-url"
  case openExternal = "open-browser-tab-in-external-browser"
  case rename = "rename-browser-tab"
  case close = "close-tab"
  var title: String {
    switch self {
    case .reload: "重新加载"
    case .duplicate: "复制标签页"
    case .copyURL: "复制 URL"
    case .openExternal: "在外部浏览器中打开"
    case .rename: "重命名"
    case .close: "关闭"
    }
  }
  static func externalURLIsAvailable(_ url: URL) -> Bool {
    url.absoluteString.range(of: "^(?:[a-z][a-z0-9+.-]*:|www\\.|//)",
      options: [.regularExpression, .caseInsensitive]) != nil
  }
  static func available(url: URL?, isWeb: Bool = true, isDefaultBrowser: Bool) -> [Self] {
    var actions: [Self] = [.reload, .duplicate]
    if isWeb, let url, url.scheme != nil, !url.absoluteString.hasPrefix("about:blank") { actions.append(.copyURL) }
    if let url, externalURLIsAvailable(url), !isDefaultBrowser { actions.append(.openExternal) }
    actions += [.rename, .close]
    return actions
  }
}

extension WorkspaceStore {
  var shipiosIsDefaultBrowser: Bool {
    guard let url = URL(string: "https://example.invalid"),
      let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
    return Bundle(url: app)?.bundleIdentifier == "dev.shipios.desktop"
  }
  private var pinnedBrowserActionsAllowed: Bool {
    destination == .workspace && !shuttingDown && !preparingProjectScope && !mainRenameDialogActive
      && !libraryRecoveryBlocksInteraction && presentedOverlay == nil && !hasSettingsConfirmation
      && editingProject == nil && renameProjectPath == nil && sidebarGroupEditor == nil
      && !showingModelPicker && !showingBranchPicker && !showingTaskStatus
      && !workspace.showingCommitPush && !workspace.showingPullRequest && !workspace.showingManagedBranchSetup
  }
  func pinnedBrowserActionContext(_ pinID: String, isDefaultBrowser: Bool? = nil) -> PinnedBrowserActionContext? {
    guard pinnedBrowserActionsAllowed,
      let pin = library.pinnedContentTabs.first(where: { $0.id == pinID }),
      let (session, page) = pinnedBrowserSource(pin), let placement = pinnedBrowserPlacement(pin) else { return nil }
    let generation = pinnedBrowserActionGenerations[pin.id] ?? UUID()
    pinnedBrowserActionGenerations[pin.id] = generation
    return .init(pin: pin, session: session, page: page, project: workspaceTabProject(owner: pin.owner)?.path,
      placement: placement, generation: generation,
      actions: PinnedBrowserAction.available(url: page.committedURL, isDefaultBrowser: isDefaultBrowser ?? shipiosIsDefaultBrowser))
  }
  private func pinnedBrowserPlacement(_ pin: PinnedWorkspaceTab) -> WorkspaceTabPlacement? {
    if let id = pin.sourceWindowID {
      return taskWindowResources.allObjects.first { $0.id == id }?.tasks[pin.owner]?.placement(pin.sourceTabID)
    }
    return workspaceTabPlacement(pin.sourceTabID)
  }
  func pinnedBrowserActionIsCurrent(_ context: PinnedBrowserActionContext) -> Bool {
    guard pinnedBrowserActionsAllowed,
      pinnedBrowserActionGenerations[context.pin.id] == context.generation,
      let pin = library.pinnedContentTabs.first(where: { $0.id == context.pin.id }),
      pin == context.pin, pinnedBrowserPlacement(pin) == context.placement,
      workspaceTabProject(owner: pin.owner)?.path == context.project,
      let (session, page) = pinnedBrowserSource(pin) else { return false }
    return session === context.session && page === context.page
  }

  @discardableResult func performPinnedBrowserAction(_ action: PinnedBrowserAction,
    context: PinnedBrowserActionContext, pasteboard: NSPasteboard = .general,
    openExternal: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
    guard context.actions.contains(action), pinnedBrowserActionIsCurrent(context) else { return false }
    let page = context.page, session = context.session
    switch action {
    case .reload: page.reload()
    case .duplicate:
      // Reuse the owner-aware child route. Address-bar drafts are not navigation.
      guard let child = session.newChildTab(from: page.id) else { return false }
      if let url = page.committedURL {
        child.address = url.absoluteString
        if url.absoluteString == "about:blank" { child.view.load(URLRequest(url: url)) }
        else { child.navigate() }
      }
      if let id = context.pin.sourceWindowID {
        taskWindowResources.allObjects.first { $0.id == id }?.capturePins()
      } else if context.pin.owner != currentWorkspaceTabOwner,
        var layout = library.workspaceTabLayouts[context.pin.owner] {
        let id = "browser:\(child.id)"
        if context.placement == .left || layout.contentLayoutMode == .full { layout.active = id }
        else { layout.right = id; layout.showingInspector = true }
        layout.focused = id
        library.workspaceTabLayouts[context.pin.owner] = layout
      }
      saveLibrary()
    case .copyURL:
      guard let url = page.committedURL, url.scheme != nil, !url.absoluteString.hasPrefix("about:blank") else { return false }
      guard session.copyURL(tabID: page.id, to: pasteboard) else { return false }
      let messages = context.pin.sourceWindowID.flatMap { id in
        taskWindowResources.allObjects.first { $0.id == id }?.notices
      } ?? notices
      messages.show(id: "browser-url-copied", title: "URL 已复制到剪贴板", level: .success, taskID: context.pin.owner)
    case .openExternal:
      guard let url = page.committedURL, PinnedBrowserAction.externalURLIsAvailable(url) else { return false }
      return openExternal(url)
    case .rename: return beginPinnedBrowserRename(context.pin.id)
    case .close:
      // Preserve the latest source URL/title before removing its live instance.
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == context.pin.id }) {
        library.pinnedContentTabs[index].title = page.title
        library.pinnedContentTabs[index].browserCustomTitle = page.customTitle
        library.pinnedContentTabs[index].restoreURL = page.committedURL?.absoluteString ?? page.address
      }
      if let id = context.pin.sourceWindowID {
        guard let tabs = taskWindowResources.allObjects.first(where: { $0.id == id })?.tasks[context.pin.owner] else { return false }
        tabs.close(context.pin.sourceTabID)
      } else { closeWorkspaceTab(context.pin.sourceTabID) }
      saveLibrary()
    }
    return true
  }
}
