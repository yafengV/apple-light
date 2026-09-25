import AppKit
import Observation

@MainActor @Observable final class DetachedWindowSearch {
  private(set) var mode: TaskWindowSearchMode?
  @ObservationIgnored private var returnFocus: SearchDialogReturnFocus?
  private static let globalCommands: Set<String> = [
    "settings", "shortcuts", "projects", "plugins", "automations", "new", "new-alternate", "open", "pet", "clear-unread"
  ]

  func open(_ mode: TaskWindowSearchMode, window: NSWindow?) {
    if self.mode == nil { returnFocus = SearchDialogReturnFocus(window: window, destination: .workspace) }
    self.mode = mode
  }
  func close(restoreFocus: Bool = true) {
    if !restoreFocus { returnFocus = nil }
    mode = nil
  }
  func restoreFocus() {
    let source = returnFocus; returnFocus = nil
    source?.restore { [weak self] in self?.mode == nil }
  }

  private func available(_ store: WorkspaceStore, tabID: String) -> Bool {
    !store.shuttingDown && !store.restoringLibrary && store.workspaceTabPlacement(tabID) == .detached
      && store.workspaceTabs.contains { $0.id == tabID }
  }

  func commands(store: WorkspaceStore, tabID: String, closeWindow: @escaping () -> Void) -> TaskWindowCommandContext {
    let local = store.detachedWindowCommands(tabID, close: closeWindow)
    let enabled = mode == nil && available(store, tabID: tabID)
      ? local.enabled.union(["palette", "palette-alternate", "search"]) : []
    return TaskWindowCommandContext(enabled: enabled, perform: { [weak self] id in
      guard let self, self.mode == nil, self.available(store, tabID: tabID) else { return }
      if id == "palette" || id == "palette-alternate" { self.open(.commands, window: NSApp.keyWindow) }
      else if id == "search" { self.open(.tasks, window: NSApp.keyWindow) }
      else { local.execute(id) }
    }, closeTitle: local.closeTitle, keyboardAllowed: local.keyboardAllowed)
  }

  func context(store: WorkspaceStore, tabID: String, closeWindow: @escaping () -> Void,
    showMain: @escaping () -> Void, showDetached: @escaping (WorkspaceTabWindowRoute) -> Void) -> SearchDialogContext {
    SearchDialogContext(currentTaskID: store.workspaceTabs.first { $0.id == tabID }?.owner ?? "",
      commandEnabled: { [weak self] id in
        guard let self, self.mode == .commands, self.available(store, tabID: tabID) else { return false }
        if ["palette", "palette-alternate", "search"].contains(id) { return true }
        if TaskWindowCommandContext.owns(id) {
          return store.detachedWindowCommands(tabID, close: closeWindow).enabled.contains(id)
        }
        return Self.globalCommands.contains(id) && store.commandEnabled(id)
      }, performCommand: { [weak self] id in
        guard let self else { return }
        if id == "palette" || id == "palette-alternate" { return }
        if id == "search" { self.mode = .tasks; return }
        if TaskWindowCommandContext.owns(id) {
          self.close(restoreFocus: !["tab-close", "browser-close", "browser-new", "browser-address"].contains(id))
          store.detachedWindowCommands(tabID, close: closeWindow).execute(id)
        } else {
          let staysHere = id == "pet" || id == "clear-unread"
          self.close(restoreFocus: staysHere)
          store.executeCommand(id)
          if !staysHere { showMain() }
        }
      }, canSelectTask: { [weak self] candidate in
        guard let self, self.mode != nil, self.available(store, tabID: tabID),
          let current = store.library.tasks.first(where: { $0.id == candidate.id }) else { return false }
        return store.canSelectTask(current)
      }, navigate: { [weak self] candidate in
        guard let current = store.library.tasks.first(where: { $0.id == candidate.id }) else { return }
        self?.close(restoreFocus: false)
        store.selectTask(current)
        showMain()
      }, cancel: { [weak self] in self?.close() }, browserResults: store.allCommandBrowserTabs,
      canOpenBrowser: { [weak self] result in
        guard let self, self.mode == .commands, self.available(store, tabID: tabID),
          store.allCommandBrowserTabs.contains(where: { $0.id == result.id && $0.owner == result.owner }) else { return false }
        return store.detachedWorkspaceTabRoute(result.id) != nil || store.canOpenCommandBrowserTab(result)
      }, openBrowser: { [weak self] result in
        self?.close(restoreFocus: false)
        if let route = store.detachedWorkspaceTabRoute(result.id) { showDetached(route) }
        else { Task { if await store.openCommandBrowserTab(result) { showMain() } } }
      })
  }
}
