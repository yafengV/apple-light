import AppKit
import Observation

@MainActor @Observable final class TaskWindowResources {
  let id = UUID().uuidString
  @ObservationIgnored weak var window: NSWindow?
  @ObservationIgnored private weak var windowAttachment: NSView?
  @ObservationIgnored weak var store: WorkspaceStore?
  @ObservationIgnored var navigate: ((String) -> Void)?
  let browsers = TaskWindowBrowsers()
  let panels = TaskWindowPanelSessions()
  private(set) var tasks: [String: TaskWindowTabs] = [:]

  func attach(window: NSWindow?, from view: NSView) {
    if let window {
      windowAttachment = view
      self.window = window
    } else if windowAttachment === view {
      windowAttachment = nil
      self.window = nil
    }
  }

  func prepare(_ taskID: String, store: WorkspaceStore) {
    self.store = store
    store.taskWindowResources.add(self)
    capturePins()
    let project = store.library.tasks.first { $0.id == taskID }?.project ?? ""
    let oldRoot = panels.tasks[taskID]?.workspace.root
    let panel = panels.panels(for: taskID, project: project)
    store.additionalTaskWindowPanels.add(panels)
    if let existing = tasks[taskID] {
      if oldRoot != panel.workspace.root { existing.resetProjectTabs() }
    } else {
      tasks[taskID] = TaskWindowTabs(taskID: taskID,
        browser: browsers.browser(for: taskID, store: store), panels: panel)
      tasks[taskID]?.onTabWillClose = { [weak self] _ in self?.capturePins() }
      tasks[taskID]?.onTabReplaced = { [weak self] old, new in
        guard let self, let store = self.store else { return }
        for index in store.library.pinnedContentTabs.indices
          where store.library.pinnedContentTabs[index].sourceWindowID == id
            && store.library.pinnedContentTabs[index].sourceTabID == old {
          store.library.pinnedContentTabs[index].sourceTabID = new
        }
        capturePins()
        store.saveLibrary()
      }
      tasks[taskID]?.browser.session.onVisit = { [weak self, weak store] url, title in
        store?.recordBrowserVisit(url, title: title)
        self?.capturePins()
      }
    }
  }
  func retainTasks(_ available: Set<String>, displaying: String?) {
    panels.retainTasks(available, displaying: displaying)
    for id in Array(tasks.keys) where !available.contains(id) {
      tasks[id]?.resetProjectTabs()
      if id != displaying { tasks[id] = nil }
    }
  }
  func contains(_ pin: PinnedWorkspaceTab) -> Bool {
    pin.sourceWindowID == id && store?.library.tasks.contains { $0.id == pin.owner } == true
      && tasks[pin.owner]?.tabs.contains { $0.id == pin.sourceTabID } == true
  }
  func title(for pin: PinnedWorkspaceTab) -> String? {
    guard contains(pin), let tabs = tasks[pin.owner],
      let tab = tabs.tabs.first(where: { $0.id == pin.sourceTabID }) else { return nil }
    return tabs.title(tab)
  }
  func pin(_ tabID: String, taskID: String) {
    guard let store, let tabs = tasks[taskID], let tab = tabs.tabs.first(where: { $0.id == tabID }) else { return }
    store.addPinnedWorkspaceTab(reference(tab, tabs: tabs))
  }
  private func reference(_ tab: WorkspaceContentTab, tabs: TaskWindowTabs) -> PinnedWorkspaceTab {
    let browser = tab.browserID.flatMap { id in tabs.browser.session.tabs.first { $0.id == id } }
    return PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: tab.owner,
      kind: tab.browserID != nil ? .browser : tab.terminalID != nil ? .terminal : .review,
      title: tabs.title(tab), restoreURL: browser?.committedURL?.absoluteString ?? browser?.address,
      sourceWindowID: id)
  }
  func capturePins() {
    guard let store else { return }
    var changed = false
    for index in store.library.pinnedContentTabs.indices {
      let pin = store.library.pinnedContentTabs[index]
      guard contains(pin), let tabs = tasks[pin.owner],
        let tab = tabs.tabs.first(where: { $0.id == pin.sourceTabID }) else { continue }
      var updated = reference(tab, tabs: tabs)
      updated.id = pin.id
      if updated != pin { store.library.pinnedContentTabs[index] = updated; changed = true }
    }
    if changed { store.saveLibrary() }
  }
  @discardableResult func reveal(_ pin: PinnedWorkspaceTab) -> Bool {
    guard contains(pin), let window, let navigate,
      let tabs = tasks[pin.owner], store?.library.tasks.contains(where: { $0.id == pin.owner }) == true else { return false }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // AppKit restores the window's former responder while making it key.
    // Request the pinned content's focus only after that restoration.
    navigate(pin.owner)
    tabs.activate(pin.sourceTabID)
    return true
  }
  func shutdown() {
    capturePins()
    browsers.shutdown(); panels.shutdown(); tasks.removeAll()
    navigate = nil; window = nil; windowAttachment = nil
  }
}
