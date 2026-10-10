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
  let worktreeForkPresentation = WorktreeForkPresentation()
  struct WorktreeRestoreWait: Equatable {
    let taskID: String
    let message: String
  }
  private(set) var worktreeRestoreWait: WorktreeRestoreWait?
  @ObservationIgnored private var worktreeForkRequest: Task<Void, Never>?
  @ObservationIgnored private var worktreeForkRequestID: UUID?
  @ObservationIgnored private var worktreeForkNavigationRevision = UUID()
  @ObservationIgnored private(set) var isClosed = false
  let browsers = TaskWindowBrowsers()
  let panels = TaskWindowPanelSessions()
  let files = TaskWindowFileEditors()

  func fileWorkspace(_ tab: WorkspaceContentTab) -> DeveloperWorkspace {
    files.workspace(for: tab, store: store, windowID: id)
  }
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
    if displayedTaskID != taskID { invalidateWorktreeForkNavigation() }
    displayedTaskID = taskID
  }

  /// Leaving a page invalidates queued starts while an already-started worker can finish in the background.
  func invalidateWorktreeForkNavigation() {
    worktreeForkNavigationRevision = UUID()
    worktreeForkPresentation.dismiss()
    worktreeRestoreWait = nil
  }

  /// Cold windows cannot mount editors until their saved checkout has finished preparing.
  @discardableResult func restorePendingWorktree(_ taskID: String, store: WorkspaceStore) -> Task<Void, Never>? {
    guard !isClosed, !store.shuttingDown else { return nil }
    if let preparation = store.activeWorktreeForkPreparation, preparation.taskID == taskID {
      worktreeRestoreWait = nil
      worktreeForkPresentation.present(preparation)
      return worktreeForkRequest
    }
    if let blocker = store.worktreeForkResumeBlocker(taskID) {
      worktreeRestoreWait = .init(taskID: taskID, message: blocker)
      return nil
    }
    worktreeRestoreWait = nil
    return forkToNewWorktree(taskID, store: store, resume: true)
  }

  @discardableResult func forkToNewWorktree(_ taskID: String, store: WorkspaceStore,
    resume: Bool = false) -> Task<Void, Never>? {
    guard !isClosed, !store.busy, !store.managedTaskPreparing, !store.shuttingDown,
      resume ? store.worktreeForkResumeBlocker(taskID) == nil : store.canForkTaskToNewWorktree(taskID)
      else { return nil }
    self.store = store
    store.taskWindowResources.add(self)
    let requestID = UUID()
    worktreeForkRequestID = requestID
    let navigationRevision = worktreeForkNavigationRevision
    let originalWindowID = id
    let originalDisplayedTaskID = displayedTaskID
    worktreeForkPresentation.onReady = { [weak self] fork in
      guard let self, worktreeForkRequestID == requestID,
        id == originalWindowID, displayedTaskID == originalDisplayedTaskID,
        !store.shuttingDown else { return }
      navigate?(fork.id)
    }
    worktreeForkRequest = Task {
      defer {
        if worktreeForkRequestID == requestID { worktreeForkRequest = nil }
      }
      guard !Task.isCancelled, worktreeForkRequestID == requestID,
        worktreeForkNavigationRevision == navigationRevision, id == originalWindowID,
        displayedTaskID == originalDisplayedTaskID, !store.shuttingDown else { return }
      if resume {
        let result = await store.resumeWorktreeFork(taskID, openTask: false,
          presentation: worktreeForkPresentation, noticeBoard: notices)
        // Admission may change between queuing this action and starting its worker.
        if result == nil, !Task.isCancelled, worktreeForkRequestID == requestID,
          worktreeForkNavigationRevision == navigationRevision,
          !store.shuttingDown, worktreeForkPresentation.preparation == nil {
          worktreeRestoreWait = .init(taskID: taskID,
            message: store.worktreeForkResumeBlocker(taskID) ?? "工作树尚未恢复，请重试。")
        }
      } else {
        _ = await store.forkTaskToNewWorktree(taskID, openTask: false,
          presentation: worktreeForkPresentation, noticeBoard: notices)
      }
    }
    return worktreeForkRequest
  }

  func register(store: WorkspaceStore, windowID: String? = nil) {
    if tasks.isEmpty, let windowID, id != windowID {
      id = windowID
      invalidateWorktreeForkNavigation()
    }
    self.store = store
    store.taskWindowResources.add(self)
  }

  func prepare(_ taskID: String, store: WorkspaceStore, windowID: String? = nil) {
    register(store: store, windowID: windowID)
    capturePins()
    captureLayouts()
    let project = store.library.tasks.first { $0.id == taskID }?.project ?? ""
    let oldRoot = panels.tasks[taskID]?.workspace.root
    let nextRoot = project.isEmpty ? nil : GitBranchService.canonicalRoot(URL(fileURLWithPath: project))
    if oldRoot != nextRoot, let old = panels.tasks[taskID]?.workspace {
      store.captureFileEditorRecovery(from: old)
    }
    let panel = panels.panels(for: taskID, project: project)
    store.bindFileEditorRecovery(to: panel.workspace, context: .init(kind: .taskTree, windowID: id, owner: taskID))
    store.bindGitReviewPolicy(to: panel.workspace, taskID: taskID)
    store.additionalTaskWindowPanels.add(panels)
    if let existing = tasks[taskID] {
      if oldRoot != panel.workspace.root {
        files.remove(owner: taskID, store: store)
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
      tasks[taskID]?.onTabWillClose = { [weak self] tab in
        self?.capturePins()
      }
      tasks[taskID]?.isTabPinned = { [weak self, weak store] tabID in
        guard let self else { return false }
        return store?.isWorkspaceTabPinned(tabID, windowID: self.id) == true
      }
      tasks[taskID]?.onTabReplaced = { [weak self] old, new in
        guard let self, let store = self.store else { return }
        files.rekey(old, to: tasks[taskID]?.tabs.first { $0.id == new }, store: store)
        for index in store.library.pinnedContentTabs.indices
          where store.library.pinnedContentTabs[index].sourceWindowID == id
            && store.library.pinnedContentTabs[index].sourceTabID == old {
          store.library.pinnedContentTabs[index].sourceTabID = new
        }
        capturePins()
        store.saveLibrary()
      }
      tasks[taskID]?.browser.session.onVisit = { [weak self, weak store] url, title, newVisit in
        store?.recordBrowserVisit(url, title: title, newVisit: newVisit)
        self?.capturePins()
      }
      tasks[taskID]?.browser.session.onTabRenamed = { [weak self, weak store] _ in
        self?.capturePins()
        store?.saveLibrary()
      }
      if store.libraryLoaded, let layout = store.library.taskWindowTabLayouts[id]?[taskID] {
        if !store.automationsLoaded, layout.content.tabs.contains(where: { $0.kind == .pullRequestWatch }) {
          deferredLayouts[taskID] = layout
        } else { tasks[taskID]?.restoreLayout(layout) }
      }
    }
    tasks[taskID]?.canCloseFileTab = { [weak self] tab in
      guard let self, let session = files.existing(tab), let path = session.selectedFile,
        session.selectedFileEditor.map({ $0.hasUnsavedChanges || $0.saving }) == true else { return true }
      tasks[taskID]?.activate(tab.id)
      session.closeFile(path)
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

  func closeFileContentTab(_ tab: WorkspaceContentTab, taskID: String, editor: DeveloperWorkspace) {
    guard files.existing(tab) === editor, let target = tasks[taskID], target.tabs.contains(tab) else { return }
    target.close(tab.id)
  }
  func restoreDeferredWatchLayouts() {
    guard store?.automationsLoaded == true else { return }
    for (taskID, layout) in deferredLayouts { tasks[taskID]?.restoreDeferredWatchLayout(layout) }
    deferredLayouts.removeAll()
  }
  func retainTasks(_ available: Set<String>, displaying: String?) {
    files.retain(available, store: store)
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
    guard pin.sourceWindowID == id, let store,
      store.library.tasks.contains(where: { $0.id == pin.owner }),
      let tabs = tasks[pin.owner], let tab = tabs.tabs.first(where: { $0.id == pin.sourceTabID }) else { return false }
    guard case .file(let currentPath, _) = tab, let savedRoot = pin.fileRoot else { return true }
    guard let root = store.validatedWorkspaceFileRoot(savedRoot) else { return false }
    let path = pin.restoreURL ?? currentPath
    if path.isEmpty || currentPath.isEmpty {
      return path.isEmpty && currentPath.isEmpty && root == tabs.panels.workspace.root
    }
    guard let original = try? WorkspaceFileScope.location(path,
      roots: [root] + store.additionalWorkspaceFolders(for: root)),
      let current = try? tabs.panels.workspace.fileLocation(currentPath) else { return false }
    return original.url == current.url
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
      sourceWindowID: id, fileRoot: tab.kind == .file ? tabs.panels.workspace.root?.path : nil,
      watchAutomationID: tab.watchAutomationID, watchTaskID: tab.watchTaskID,
      browserCustomTitle: browser?.customTitle)
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
  var fileRecoveryWorkspaces: [DeveloperWorkspace] {
    files.allWorkspaces + panels.tasks.values.map(\.workspace)
  }

  func prepareToClose() -> Bool {
    guard let store else { return true }
    let saved = store.captureFileEditorRecovery(from: fileRecoveryWorkspaces, includePending: false, forceSave: true)
    if saved { notices.completeAndDismiss("file-recovery-save") }
    else {
      notices.show(id: "file-recovery-save", title: store.error ?? "无法保存文件草稿。",
        description: "草稿尚未保存。请检查数据目录后重试关闭。", level: .error)
    }
    return saved
  }

  @discardableResult func shutdown(force: Bool = false) -> Bool {
    let saved = prepareToClose()
    guard saved || force else { return false }
    isClosed = true
    worktreeRestoreWait = nil
    worktreeForkRequest?.cancel(); worktreeForkRequest = nil
    worktreeForkRequestID = nil
    worktreeForkNavigationRevision = UUID()
    worktreeForkPresentation.close()
    // Foundation's persistence/weak-registry bridging can autorelease references
    // to this window. Drain them before returning from explicit window teardown.
    autoreleasepool {
      for panel in panels.tasks.values { store?.captureFileEditorRecovery(from: panel.workspace) }
      captureLayouts()
      capturePins()
      files.shutdown(store: store)
      store?.taskWindowResources.remove(self)
      browsers.shutdown(); panels.shutdown(); tasks.removeAll()
      deferredLayouts.removeAll()
      navigate = nil; window = nil; windowAttachment = nil; displayedTaskID = nil
      store?.saveLibrary()
    }
    return saved
  }
}
