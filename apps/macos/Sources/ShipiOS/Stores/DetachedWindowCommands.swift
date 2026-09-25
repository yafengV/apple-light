import AppKit

extension WorkspaceStore {
  func detachedWindowCommands(_ tabID: String, close: @escaping () -> Void) -> TaskWindowCommandContext {
    var enabled: Set<String> = []
    if !shuttingDown, let tab = workspaceTabs.first(where: { $0.id == tabID }),
      workspaceTabPlacement(tabID) == .detached {
      enabled.insert("tab-close")
      if let id = tab.browserID, let page = workspace.browser.tabs.first(where: { $0.id == id }) {
        enabled.formUnion(["browser-address", "browser-reload", "browser-reload-origin", "browser-close"])
        if page.canGoBack { enabled.formUnion(["browser-back", "back"]) }
        if page.canGoForward { enabled.formUnion(["browser-forward", "forward"]) }
        if page.committedURL != nil { enabled.insert("browser-copy") }
      }
    }
    return TaskWindowCommandContext(enabled: enabled, perform: { [weak self] id in
      guard let self, !self.shuttingDown,
        self.workspaceTabPlacement(tabID) == .detached,
        let tab = self.workspaceTabs.first(where: { $0.id == tabID }) else { return }
      if id == "tab-close" { close(); return }
      guard let browserID = tab.browserID,
        let page = self.workspace.browser.tabs.first(where: { $0.id == browserID }) else { return }
      switch id {
      case "browser-address": self.workspace.browser.focusAddress(tabID: browserID)
      case "browser-back", "back": page.back()
      case "browser-forward", "forward": page.forward()
      case "browser-reload": page.reload()
      case "browser-reload-origin": page.reload(bypassCache: true)
      case "browser-copy": self.workspace.browser.copyURL(tabID: browserID)
      case "browser-close": self.closeBrowserTab(browserID); close()
      default: break
      }
    }, closeTitle: "关闭标签页窗口", keyboardAllowed: { [weak self] id in
      guard id != "browser-address", BrowserKeyboardBridge.contextualCommands.contains(id) else { return true }
      guard let self, let browserID = self.workspaceTabs.first(where: { $0.id == tabID })?.browserID else { return false }
      return self.workspace.browser.hasNativeFocus(tabID: browserID)
    })
  }
}
