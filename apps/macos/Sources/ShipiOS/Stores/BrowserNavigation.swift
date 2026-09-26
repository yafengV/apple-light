import AppKit

extension WorkspaceStore {
  var browserVisible: Bool {
    destination == .workspace
      && (activeBrowserTabID != nil || activeRightWorkspaceContentTab?.browserID != nil
        || (showingInspector && pane == "browser"))
  }
  var browserFocused: Bool { browserVisible && presentedOverlay == nil && !showingModelPicker
    && !showingBranchPicker && workspace.browser.hasNativeFocus }
  var pageFindTab: BrowserTab? {
    guard browserVisible else { return nil }
    let id: UUID?
    if let focusedWorkspaceContentTab { id = focusedWorkspaceContentTab.browserID }
    else if browserFocused { id = workspace.browser.selection }
    else { id = activeWorkspaceContentTab?.browserID }
    return workspace.browser.tabs.first { $0.id == id }
  }
  func newBrowserTab() {
    newBrowserTab(in: .left)
  }
  func newBrowserTab(in placement: WorkspaceTabPlacement) {
    destination = .workspace
    let previousLeft = activeWorkspaceTabID
    let tab = workspace.browser.newTab()
    let id = WorkspaceContentTab.browser(tab.id, owner: currentWorkspaceTabOwner).id
    if placement != .left {
      moveWorkspaceTab(id, to: placement)
      activeWorkspaceTabID = previousLeft
    }
  }
  func closeBrowserTab(_ id: UUID) {
    workspace.browser.close(id)
  }
  func reopenClosedBrowserTab() {
    reopenClosedWorkspaceTab()
  }
  func copyBrowserURL(to pasteboard: NSPasteboard = .general) {
    guard let url = workspace.browser.selected?.committedURL else { return }
    pasteboard.clearContents(); pasteboard.setString(url.absoluteString, forType: .string)
  }
  func addBrowserElementToDraft(_ reference: BrowserElementReference, taskID: String? = nil) {
    if let taskID {
      guard taskID.hasPrefix("new:") || library.tasks.contains(where: { $0.id == taskID }) else { return }
      let draft = taskWindowDraft(taskID)
      library.drafts[taskID] = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? reference.promptContext : draft + "\n\n" + reference.promptContext
      saveLibrary()
      return
    }
    let context = reference.promptContext
    draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? context : draft + "\n\n" + context
    focusComposer = UUID()
  }
  @discardableResult func captureBrowserSnapshot(
    _ tab: BrowserTab, taskID: String? = nil, fullPage: Bool = false
  ) async -> Bool {
    // Capture ownership before WebKit performs its asynchronous snapshot.
    let key = taskID ?? draftKey
    guard let data = await tab.snapshotPNG(fullPage: fullPage) else { return false }
    let host = tab.committedURL?.host?.replacingOccurrences(
      of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression) ?? "webpage"
    let prefix = fullPage ? "整页截图" : "网页截图"
    return await importImages([.bytes(data, name: "\(prefix)-\(host).png")], draft: key)
  }
  func performBrowserCommand(_ id: String) {
    let browser = workspace.browser
    switch id {
    case "browser-address": browser.focusAddress()
    case "browser-back": browser.selected?.back()
    case "browser-forward": browser.selected?.forward()
    case "browser-reload": browser.selected?.reload()
    case "browser-reload-origin": browser.selected?.reload(bypassCache: true)
    case "browser-copy": copyBrowserURL()
    case "browser-close":
      if activeBrowserTabID != nil { closeActiveWorkspaceTab() }
      else if let id = browser.selection { closeBrowserTab(id) }
    case "browser-reopen": reopenClosedBrowserTab()
    default: break
    }
  }
}
