import AppKit
import Observation

@MainActor @Observable final class TaskWindowResources {
  @ObservationIgnored private(set) var id = UUID().uuidString
  @ObservationIgnored weak var window: NSWindow?
  @ObservationIgnored private(set) var displayedTaskID: String?
  @ObservationIgnored private weak var windowAttachment: NSView?
  @ObservationIgnored weak var store: WorkspaceStore?
  @ObservationIgnored var navigate: ((String) -> Void)?
  let notices = WorkspaceNotices()
  let browsers = TaskWindowBrowsers()
  let panels = TaskWindowPanelSessions()
  private(set) var tasks: [String: TaskWindowTabs] = [:]
  @ObservationIgnored private var deferredLayouts: [String: TaskWindowTabLayout] = [:]

  func attach(window: NSWindow?, from view: NSView) {
    if let window {
      windowAttachment = view
      self.window = window
    } else if windowAttachment === view {
      windowAttachment = nil
      self.window = nil
    }
  }

  func display(_ taskID: String?) {
    displayedTaskID = taskID
  }

  func prepare(_ taskID: String, store: WorkspaceStore, windowID: String? = nil) {
    if tasks.isEmpty, let windowID { id = windowID }
    self.store = store
    store.taskWindowResources.add(self)
    capturePins()
    captureLayouts()
    let project = store.library.tasks.first { $0.id == taskID }?.project ?? ""
    let oldRoot = panels.tasks[taskID]?.workspace.root
    let panel = panels.panels(for: taskID, project: project)
    store.bindFileEditorRecovery(to: panel.workspace)
    store.bindGitReviewPolicy(to: panel.workspace, taskID: taskID)
    store.additionalTaskWindowPanels.add(panels)
    if let existing = tasks[taskID] {
      if oldRoot != panel.workspace.root {
        for tab in existing.tabs where tab.kind == .file {
          if let session = store.fileTabWorkspaces[tab.id] { store.captureFileEditorRecovery(from: session) }
        }
        existing.resetProjectTabs()
      }
    } else {
      tasks[taskID] = TaskWindowTabs(taskID: taskID,
        browser: browsers.browser(for: taskID, store: store), panels: panel)
      tasks[taskID]?.backgroundTerminalTitle = { [weak store] id in
        store?.backgroundTerminalDocument(id, taskID: taskID)?.title
      }
      tasks[taskID]?.planDocument = { [weak store] runID in
        store?.taskWindowRuns(taskID).first(where: { $0.id == runID })?.codexPlanDocument
      }
      tasks[taskID]?.pullRequest = { [weak store] url in
        store?.pullRequestContent(.pullRequest(url, owner: taskID))
      }
      tasks[taskID]?.watchAutomation = { [weak store] id, target in
        store?.pullRequestWatchContent(.pullRequestWatch(id, task: target, owner: taskID))
      }
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
      if store.libraryLoaded, let layout = store.library.taskWindowTabLayouts[id]?[taskID] {
        if !store.automationsLoaded, layout.content.tabs.contains(where: { $0.kind == .pullRequestWatch }) {
          deferredLayouts[taskID] = layout
        } else { tasks[taskID]?.restoreLayout(layout) }
      }
    }
    tasks[taskID]?.canCloseFileTab = { [weak self, weak store] tab in
      guard let store, let session = store.fileTabWorkspaces[tab.id],
        session.selectedFileEditor?.hasUnsavedChanges == true else { return true }
      Task {
        if await session.saveSelectedFileEdits() { self?.tasks[taskID]?.close(tab.id) }
      }
      return false
    }
  }
  func captureLayouts() {
    guard let store, store.libraryLoaded else { return }
    for (taskID, tabs) in tasks where deferredLayouts[taskID] == nil
      && store.library.tasks.contains(where: { $0.id == taskID }) {
      store.library.taskWindowTabLayouts[id, default: [:]][taskID] = tabs.layoutSnapshot
    }
  }
  func restoreDeferredWatchLayouts() {
    guard store?.automationsLoaded == true else { return }
    for (taskID, layout) in deferredLayouts { tasks[taskID]?.restoreDeferredWatchLayout(layout) }
    deferredLayouts.removeAll()
  }
  func retainTasks(_ available: Set<String>, displaying: String?) {
    for (id, panel) in panels.tasks where !available.contains(id) {
      store?.captureFileEditorRecovery(from: panel.workspace)
    }
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
    let filePath: String? = { if case .file(let path, _) = tab { return path }; return nil }()
    return PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: tab.owner,
      kind: tab.kind, title: tabs.title(tab),
      restoreURL: filePath ?? tab.pullRequestURL ?? browser?.committedURL?.absoluteString ?? browser?.address,
      sourceWindowID: id, watchAutomationID: tab.watchAutomationID, watchTaskID: tab.watchTaskID)
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
    guard pin.sourceWindowID == id, let store, let window, let navigate,
      store.archiveConfirmation(inWindow: id) == nil,
      store.library.tasks.contains(where: { $0.id == pin.owner }) else { return false }
    if tasks[pin.owner] == nil,
      store.library.taskWindowTabLayouts[id]?[pin.owner]?.content.tabs.contains(where: { $0.id == pin.sourceTabID }) == true {
      prepare(pin.owner, store: store)
    }
    guard contains(pin), let tabs = tasks[pin.owner] else { return false }
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
    // Foundation's persistence/weak-registry bridging can autorelease references
    // to this window. Drain them before returning from explicit window teardown.
    autoreleasepool {
      for panel in panels.tasks.values { store?.captureFileEditorRecovery(from: panel.workspace) }
      captureLayouts()
      capturePins()
      store?.taskWindowResources.remove(self)
      browsers.shutdown(); panels.shutdown(); tasks.removeAll()
      deferredLayouts.removeAll()
      navigate = nil; window = nil; windowAttachment = nil; displayedTaskID = nil
      store?.saveLibrary()
    }
  }
}
