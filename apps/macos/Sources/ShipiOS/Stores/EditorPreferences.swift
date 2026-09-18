import AppKit

extension WorkspaceStore {
  func performMessageLinkAction(_ action: MessageLinkAction, url: URL, ownerRunID: String?,
    openInApp: ((URL, MessageWebLinkPresentation) -> Void)? = nil,
    pasteboard: NSPasteboard = .general, openExternal: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    guard BrowserAddress.permits(url) else { return }
    switch action {
    case .openInApp:
      if let openInApp { openInApp(url, .split) }
      else { Task { await openWebLinkInApp(url, ownerRunID: ownerRunID) } }
    case .openExternal:
      if !openExternal(url) { error = "无法打开此链接。" }
    case .copy:
      pasteboard.clearContents()
      pasteboard.setString(url.absoluteString, forType: .string)
    case .saveAs: downloadMessageLink(url, askWhereToSave: true)
    }
  }

  func openMessageLink(_ url: URL, project: URL?, ownerRunID: String? = nil,
    click: WebLinkClick? = nil, openInApp: ((URL, MessageWebLinkPresentation) -> Void)? = nil,
    openExternal: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    do {
      switch try MessageLink.target(url, root: project) {
      case .web(let url):
        switch messageWebLinkBehavior(url, click: click) {
        case .inApp(let presentation):
          if let openInApp { openInApp(url, presentation) }
          else { Task { await openWebLinkInApp(url, ownerRunID: ownerRunID, presentation: presentation) } }
        case .external:
          if !openExternal(url) { error = "无法打开此链接。" }
        case .download:
          downloadMessageLink(url)
        }
      case .file(let path, let line):
        guard let project else { return }
        Task {
          do {
            try await ExternalEditorService.open(
              path, root: project, line: line, editor: preferredEditor)
          } catch { self.error = error.localizedDescription }
        }
      }
    } catch { self.error = error.localizedDescription }
  }

  func messageWebLinkBehavior(_ url: URL, click: WebLinkClick?) -> MessageWebLinkBehavior {
    MessageWebLinkBehavior.resolve(url: url, click: click,
      preference: webLinkTarget, shortcut: shortcuts.externalBrowserLinkShortcut)
  }

  func openWebLinkInApp(_ url: URL, ownerRunID: String?,
    presentation: MessageWebLinkPresentation = .split) async {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
    let task = library.task(containing: ownerRunID)
    guard ownerRunID == nil || task != nil else {
      error = "链接所属的任务已不可用。"
      return
    }
    if presentation == .backgroundTab {
      let owner = task?.id ?? currentWorkspaceTabOwner
      reopeningWorkspaceTabOwner = owner
      let tab = workspace.browser.newTab(activate: false)
      reopeningWorkspaceTabOwner = nil
      let id = WorkspaceContentTab.browser(tab.id, owner: owner).id
      workspaceTabPlacements[id] = .right
      if owner == currentWorkspaceTabOwner {
        if activeRightWorkspaceContentTab == nil { activeRightWorkspaceTabID = id }
        showingInspector = true
      }
      tab.address = url.absoluteString
      tab.navigate()
      return
    }
    if let task {
      guard canSelectTask(task) else { error = "当前任务忙碌，暂时无法打开链接所属的任务。"; return }
      if currentProjectKey != task.project {
        guard await openTaskScope(task.project) else {
          error = "无法打开链接所属的任务。"
          return
        }
      }
      guard let current = library.tasks.first(where: { $0.id == task.id }) else {
        error = "链接所属的任务已不可用。"
        return
      }
      if selectedTask?.id != current.id {
        applyTaskSelection(current)
      }
    }
    destination = .workspace
    let reusable = presentation.createsNewTab ? nil : reusableMessageBrowserTab(for: url)
    let tab = reusable ?? workspace.browser.newTab(activate: false)
    let id = WorkspaceContentTab.browser(tab.id, owner: currentWorkspaceTabOwner).id
    moveWorkspaceTab(id, to: presentation == .fullWidth ? .left : .right)
    if presentation == .fullWidth { showingInspector = false }
    if tab.committedURL != url && (reusable == nil || tab.address != url.absoluteString || !tab.loading) {
      tab.address = url.absoluteString
      tab.navigate()
    }
    workspace.browser.focusContent(tab.id)
  }

  private func reusableMessageBrowserTab(for url: URL) -> BrowserTab? {
    func withoutFragment(_ url: URL) -> String {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.fragment = nil
      return components?.string ?? url.absoluteString
    }
    let ids = Set(visibleWorkspaceContentTabs.compactMap(\.browserID))
    let candidates = workspace.browser.tabs.filter { tab in
      guard ids.contains(tab.id), !tab.closed else { return false }
      if let committed = tab.committedURL, !tab.loading {
        return withoutFragment(committed) == withoutFragment(url)
      }
      return tab.committedURL == nil && tab.address == url.absoluteString
    }
    return candidates.first { $0.id == workspace.browser.selection } ?? candidates.last
  }
  var preferredEditor: ExternalEditor {
    get { ExternalEditor(rawValue: library.preferredEditor) ?? .system }
    set {
      library.preferredEditor = newValue.rawValue
      saveLibrary()
    }
  }
  func openProjectFile(_ path: String, root: URL, line: Int? = nil) async {
    workspace.error = nil
    do {
      try await ExternalEditorService.open(path, root: root, line: line, editor: preferredEditor)
    } catch { if workspace.root == root { workspace.error = error.localizedDescription } }
  }
}
