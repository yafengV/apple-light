import Foundation

extension WorkspaceStore {
  var currentWorkspaceTabOwner: String { draftKey }

  var visibleWorkspaceContentTabs: [WorkspaceContentTab] {
    workspaceTabs.filter { $0.owner == currentWorkspaceTabOwner }
  }

  func workspaceTabPlacement(_ id: String) -> WorkspaceTabPlacement {
    workspaceTabPlacements[id] ?? .left
  }

  func visibleWorkspaceContentTabs(in placement: WorkspaceTabPlacement) -> [WorkspaceContentTab] {
    visibleWorkspaceContentTabs.filter { workspaceTabPlacement($0.id) == placement }
  }

  var workspacePrimaryContentTabs: [WorkspaceContentTab] {
    visibleWorkspaceContentTabs.filter { [.left, .right].contains(workspaceTabPlacement($0.id)) }
  }

  /// Both layouts share one collection. Placement records opening intent, not visibility.
  func presentedWorkspaceContentTabs(in placement: WorkspaceTabPlacement) -> [WorkspaceContentTab] {
    if placement == .left || placement == .right {
      let surface: WorkspaceTabPlacement = effectiveWorkspaceContentLayoutMode == .full ? .left : .right
      return placement == surface ? workspacePrimaryContentTabs : []
    }
    return visibleWorkspaceContentTabs(in: placement)
  }

  var showsWorkspaceInspector: Bool {
    showingInspector && (effectiveWorkspaceContentLayoutMode != .full || visibleWorkspaceContentTabs(in: .right).isEmpty)
  }

  func workspaceTabStripPlacement(_ id: String) -> WorkspaceTabPlacement {
    let place = workspaceTabPlacement(id)
    return [.left, .right].contains(place)
      ? (effectiveWorkspaceContentLayoutMode == .full ? .left : .right) : place
  }

  var activeWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeWorkspaceTabID else { return nil }
    return presentedWorkspaceContentTabs(in: .left).first { $0.id == activeWorkspaceTabID }
  }


  var activeRightWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeRightWorkspaceTabID else { return nil }
    return workspacePrimaryContentTabs.first { $0.id == activeRightWorkspaceTabID }
  }

  var activeBottomWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeBottomWorkspaceTabID else { return nil }
    return visibleWorkspaceContentTabs(in: .bottom).first { $0.id == activeBottomWorkspaceTabID }
  }

  var focusedWorkspaceContentTab: WorkspaceContentTab? {
    guard destination == .workspace, let focusedWorkspaceTabID,
      let tab = visibleWorkspaceContentTabs.first(where: { $0.id == focusedWorkspaceTabID }) else { return nil }
    if [.left, .right].contains(workspaceTabPlacement(tab.id)) {
      if effectiveWorkspaceContentLayoutMode == .full { return activeWorkspaceTabID == tab.id ? tab : nil }
      return showsWorkspaceInspector && activeRightWorkspaceTabID == tab.id ? tab : nil
    }
    switch workspaceTabPlacement(tab.id) {
    case .left: return activeWorkspaceTabID == tab.id ? tab : nil
    case .right: return showingInspector && activeRightWorkspaceTabID == tab.id ? tab : nil
    case .bottom: return showingTerminal && activeBottomWorkspaceTabID == tab.id ? tab : nil
    case .detached: return nil
    }
  }

  var activeBrowserTabID: UUID? { activeWorkspaceContentTab?.browserID }

  func workspaceTabTitle(_ tab: WorkspaceContentTab) -> String {
    switch tab {
    case .browser(let id, _):
      return workspace.browser.tabs.first(where: { $0.id == id })?.title ?? "浏览器"
    case .file(let path, _): return path.isEmpty ? "打开文件" : URL(fileURLWithPath: path).lastPathComponent
    case .review: return "审查"
    case .plan(let runID, let owner):
      return taskWindowRuns(owner).first(where: { $0.id == runID })?.codexPlanDocument?.title ?? "计划"
    case .sources: return "来源"
    case .subagents: return "子任务"
    case .pullRequest:
      guard let request = pullRequestContent(tab) else { return "Pull Request" }
      let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? "Pull request #\(request.number)" : title
    case .pullRequestWatch:
      return pullRequestWatchContent(tab)?.name ?? "PR 监控进度"
    case .backgroundTerminal(let id, let owner):
      return backgroundTerminalDocument(id, taskID: owner)?.title ?? "后台终端"
    case .terminal(let id, _):
      return terminalSession(id)?.displayTitle ?? "终端"
    }
  }

  func isWorkspaceTabPinned(_ id: String, windowID: String? = nil) -> Bool {
    library.pinnedContentTabs.contains { $0.sourceTabID == id && $0.sourceWindowID == windowID }
  }

  func pinWorkspaceTab(_ id: String) {
    guard !isWorkspaceTabPinned(id),
      let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
    let reference: PinnedWorkspaceTab
    switch tab {
    case .browser(let browserID, let owner):
      let browser = workspace.browser.tabs.first { $0.id == browserID }
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .browser,
        title: browser?.title ?? "浏览器",
        restoreURL: browser?.committedURL?.absoluteString ?? browser?.address)
    case .file(let path, let owner):
      reference = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id,
        owner: owner, kind: .file, title: workspaceTabTitle(tab), restoreURL: path)
    case .review(let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .review,
        title: "审查", restoreURL: nil)
    case .plan(_, let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .plan,
        title: workspaceTabTitle(tab), restoreURL: nil)
    case .sources(let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .sources,
        title: "来源", restoreURL: nil)
    case .pullRequest(let url, let owner):
      reference = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: owner,
        kind: .pullRequest, title: workspaceTabTitle(tab), restoreURL: url)
    case .pullRequestWatch(let id, let target, let owner):
      reference = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: owner,
        kind: .pullRequestWatch, title: workspaceTabTitle(tab), restoreURL: nil,
        watchAutomationID: id, watchTaskID: target)
    case .subagents(let owner):
      reference = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: owner,
        kind: .subagents, title: "子任务", restoreURL: nil)
    case .backgroundTerminal(_, let owner):
      reference = PinnedWorkspaceTab(id: UUID().uuidString, sourceTabID: tab.id, owner: owner,
        kind: .backgroundTerminal, title: workspaceTabTitle(tab), restoreURL: nil)
    case .terminal(_, let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .terminal,
        title: workspaceTabTitle(tab), restoreURL: nil)
    }
    addPinnedWorkspaceTab(reference)
  }

  func addPinnedWorkspaceTab(_ reference: PinnedWorkspaceTab) {
    guard !isWorkspaceTabPinned(reference.sourceTabID, windowID: reference.sourceWindowID) else { return }
    library.pinnedContentTabs.append(reference)
    var order = library.sidebar.order[SidebarLayout.pinned] ?? []
    order.removeAll { $0 == SidebarItem.contentTab(reference.id).id }
    order.append(SidebarItem.contentTab(reference.id).id)
    library.sidebar.order[SidebarLayout.pinned] = order
    saveLibrary()
  }

  func unpinWorkspaceTab(_ id: String, windowID: String? = nil) {
    guard let pin = library.pinnedContentTabs.first(where: {
      $0.id == id || ($0.sourceTabID == id && $0.sourceWindowID == windowID)
    }) else { return }
    library.pinnedContentTabs.removeAll { $0.id == pin.id }
    library.sidebar.placement[SidebarItem.contentTab(pin.id).id] = nil
    for section in Array(library.sidebar.order.keys) {
      library.sidebar.order[section]?.removeAll { $0 == SidebarItem.contentTab(pin.id).id }
    }
    saveLibrary()
  }

  func pinnedWorkspaceTabTitle(_ pin: PinnedWorkspaceTab) -> String {
    if let windowID = pin.sourceWindowID {
      return taskWindowResources.allObjects.first { $0.id == windowID }?.title(for: pin) ?? pin.title
    }
    guard let source = workspaceTabs.first(where: { $0.id == pin.sourceTabID }) else {
      return pin.title
    }
    return workspaceTabTitle(source)
  }

  func pinnedWorkspaceTabIsLive(_ pin: PinnedWorkspaceTab) -> Bool {
    if let windowID = pin.sourceWindowID {
      return taskWindowResources.allObjects.first { $0.id == windowID }?.contains(pin) == true
    }
    return workspaceTabs.contains { $0.id == pin.sourceTabID }
  }

  func openPinnedWorkspaceTab(_ pinID: String) async {
    guard !Task.isCancelled, restoringPinnedContentTabIDs.insert(pinID).inserted else { return }
    defer { restoringPinnedContentTabIDs.remove(pinID) }
    guard let originalIndex = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID })
    else { return }
    let pin = library.pinnedContentTabs[originalIndex]
    if let windowID = pin.sourceWindowID,
      let resources = taskWindowResources.allObjects.first(where: { $0.id == windowID }),
      resources.reveal(pin) { return }
    if !pin.owner.hasPrefix("new:"),
      let task = library.tasks.first(where: { $0.id == pin.owner }) {
      if currentProjectKey != task.project {
        guard await openTaskScope(task.project) else { return }
      }
      // Scope loading yields: the user may unpin while the Agent is connecting.
      guard !Task.isCancelled, library.pinnedContentTabs.contains(where: {
        $0.id == pinID && $0.owner == pin.owner
      }) else { return }
      if let current = library.tasks.first(where: { $0.id == task.id }) {
        applyTaskSelection(current)
      }
    } else if pin.owner != currentWorkspaceTabOwner {
      error = "此来源标签不可用。可以保留固定项或取消固定。"
      return
    }
    destination = .workspace
    if pin.sourceWindowID == nil, workspaceTabs.contains(where: { $0.id == pin.sourceTabID }) {
      activateWorkspaceTab(pin.sourceTabID)
      return
    }
    switch pin.kind {
    case .browser:
      let browser = workspace.browser.newTab()
      if let value = pin.restoreURL, !value.isEmpty {
        browser.address = value
        browser.navigate()
      }
      let sourceID = WorkspaceContentTab.browser(browser.id, owner: currentWorkspaceTabOwner).id
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceTabID = sourceID
        library.pinnedContentTabs[index].sourceWindowID = nil
        library.pinnedContentTabs[index].owner = currentWorkspaceTabOwner
        saveLibrary()
      }
      activateWorkspaceTab(sourceID)
    case .file:
      let prefix = "file:\(pin.owner):"
      let path = pin.restoreURL ?? (pin.sourceTabID.hasPrefix(prefix)
        ? String(pin.sourceTabID.dropFirst(prefix.count)) : nil)
      guard let path, openFileTab(path) else {
        error = "此文件标签不可用。可以保留固定项或取消固定。"
        return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }),
        let tab = activeWorkspaceContentTab {
        library.pinnedContentTabs[index].sourceTabID = tab.id
        library.pinnedContentTabs[index].sourceWindowID = nil
        library.pinnedContentTabs[index].owner = currentWorkspaceTabOwner
        library.pinnedContentTabs[index].restoreURL = path
        saveLibrary()
      }
    case .review:
      guard project != nil else {
        error = "此审查标签的项目不可用。可以保留固定项或取消固定。"
        return
      }
      openReviewTab()
      if let tab = activeWorkspaceContentTab,
        let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceTabID = tab.id
        library.pinnedContentTabs[index].sourceWindowID = nil
        library.pinnedContentTabs[index].owner = currentWorkspaceTabOwner
        saveLibrary()
      }
    case .plan:
      guard pin.sourceTabID.hasPrefix("plan:") else { return }
      let runID = String(pin.sourceTabID.dropFirst(5))
      guard openPlanDocument(runID: runID) else {
        error = "此计划文档不可用。可以保留固定项或取消固定。"
        return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil
        saveLibrary()
      }
    case .sources:
      guard pin.sourceTabID == WorkspaceContentTab.sources(owner: pin.owner).id,
        openTaskSources() else {
        error = "此来源标签不可用。可以保留固定项或取消固定。"
        return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil
        saveLibrary()
      }
    case .pullRequest:
      let tab = WorkspaceContentTab.pullRequest(pin.restoreURL ?? "", owner: pin.owner)
      guard pin.sourceTabID == tab.id, let request = pullRequestContent(tab), openPullRequestContent(request) else {
        error = "此 PR 标签不可用。可以保留固定项或取消固定。"
        return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil
        saveLibrary()
      }
    case .pullRequestWatch:
      guard let id = pin.watchAutomationID, let target = pin.watchTaskID else { return }
      let tab = WorkspaceContentTab.pullRequestWatch(id, task: target, owner: pin.owner)
      guard tab.id == pin.sourceTabID, let watch = pullRequestWatchContent(tab),
        openPullRequestWatchProgress(watch) else {
        error = "此 PR 监控标签不可用。可以保留固定项或取消固定。"
        return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil
        saveLibrary()
      }
    case .subagents:
      guard pin.sourceTabID == WorkspaceContentTab.subagents(owner: pin.owner).id, openSubagents() else { return }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil; saveLibrary()
      }
    case .backgroundTerminal:
      guard let id = WorkspaceContentTab.backgroundTerminalID(pin.sourceTabID, owner: pin.owner),
        openBackgroundTerminal(id) else {
        error = "此后台终端输出不可用。可以保留固定项或取消固定。"; return
      }
      if let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceWindowID = nil; saveLibrary()
      }
    case .terminal:
      guard project != nil else {
        error = "此终端标签的项目不可用。可以保留固定项或取消固定。"
        return
      }
      let placement = library.defaultTerminalLocation
      newTerminalTab(in: placement)
      let active = placement == .right ? activeRightWorkspaceContentTab : activeBottomWorkspaceContentTab
      if let tab = active,
        let index = library.pinnedContentTabs.firstIndex(where: { $0.id == pinID }) {
        library.pinnedContentTabs[index].sourceTabID = tab.id
        library.pinnedContentTabs[index].sourceWindowID = nil
        library.pinnedContentTabs[index].owner = currentWorkspaceTabOwner
        saveLibrary()
      }
    }
  }

  func activateChatTab() {
    workspaceContentLayoutMode = effectiveWorkspaceContentLayoutMode
    activeWorkspaceTabID = nil
    focusedWorkspaceTabID = nil
    focusComposer = UUID()
  }

  func activateWorkspaceTab(_ id: String?) {
    guard let id else {
      activateChatTab()
      return
    }
    guard let tab = visibleWorkspaceContentTabs.first(where: { $0.id == id }) else { return }
    recordWorkspaceTabSelection(tab)
    switch workspaceTabPlacement(tab.id) {
    case .left, .right:
      selectWorkspacePrimaryContent(tab)
    case .bottom:
      activeBottomWorkspaceTabID = tab.id
      showingTerminal = true
    case .detached:
      break
    }
    focusedWorkspaceTabID = tab.id
    lastWorkspaceContentTabID = tab.id
    destination = .workspace
    switch tab {
    case .browser(let browserID, _):
      // Restoration may already have selected this browser without focus.
      // An explicit activation must still issue its native focus request.
      workspace.browser.select(browserID)
    case .file: break
    case .review:
      Task { await workspace.refreshGit() }
    case .plan, .sources, .pullRequest, .pullRequestWatch, .backgroundTerminal, .subagents: break
    case .terminal:
      focusTerminal()
    }
  }

  private func selectWorkspacePrimaryContent(_ tab: WorkspaceContentTab) {
    if workspaceContentLayoutMode == nil {
      workspaceContentLayoutMode = workspaceTabPlacement(tab.id) == .left ? .full : .split
      if workspaceContentLayoutMode == .full { showingInspector = false }
    }
    if effectiveWorkspaceContentLayoutMode == .full {
      activeWorkspaceTabID = tab.id
      if workspaceTabPlacement(tab.id) == .right { activeRightWorkspaceTabID = tab.id }
    } else {
      activeWorkspaceTabID = nil
      activeRightWorkspaceTabID = tab.id
      showingInspector = true
    }
  }

  var numberedWorkspaceTabIDs: [String?] {
    effectiveWorkspaceContentLayoutMode.numberedTabIDs(workspacePrimaryContentTabs,
      rightToLeft: workspaceContentRightToLeft)
  }

  @discardableResult func focusWorkspaceTab(at index: Int) -> Bool {
    let ids = numberedWorkspaceTabIDs
    guard ids.indices.contains(index) else { return false }
    activateWorkspaceTab(ids[index])
    return true
  }

  func openReviewTab() {
    openReviewTab(in: .left)
  }

  @discardableResult func openFileTab(_ path: String = "", in placement: WorkspaceTabPlacement = .left) -> Bool {
    guard placement != .bottom, let root = workspaceTabProject(owner: currentWorkspaceTabOwner) else { return false }
    var normalizedPath = path
    if !path.isEmpty {
      do {
        let location = try WorkspaceFileScope.location(path,
          roots: [root] + additionalWorkspaceFolders(for: root))
        normalizedPath = WorkspaceFileScope.key(location, primary: root)
      }
      catch { self.error = error.localizedDescription; return false }
    }
    let tab = WorkspaceContentTab.file(normalizedPath, owner: currentWorkspaceTabOwner)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
    moveWorkspaceTab(tab.id, to: placement)
    activateWorkspaceTab(tab.id)
    return true
  }

  func openReviewTab(in placement: WorkspaceTabPlacement) {
    guard project != nil else { return }
    let tab = WorkspaceContentTab.review(owner: currentWorkspaceTabOwner)
    if !workspaceTabs.contains(tab) {
      workspaceTabs.append(tab)
      workspace.selectedReviewScope = library.gitPreferences.defaultReviewScope
    }
    moveWorkspaceTab(tab.id, to: placement)
    activateWorkspaceTab(tab.id)
  }

  @discardableResult func openPlanDocument(runID: String) -> Bool {
    guard let task = selectedTask, task.runIDs.contains(runID),
      taskWindowRuns(task.id).first(where: { $0.id == runID })?.codexPlanDocument != nil else { return false }
    let tab = WorkspaceContentTab.plan(runID, owner: task.id)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
    moveWorkspaceTab(tab.id, to: .left)
    activateWorkspaceTab(tab.id)
    return true
  }

  @discardableResult func openTaskSources() -> Bool {
    guard let task = selectedTask else { return false }
    let tab = WorkspaceContentTab.sources(owner: task.id)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
    moveWorkspaceTab(tab.id, to: .left)
    activateWorkspaceTab(tab.id)
    return true
  }

  func closeActiveWorkspaceTab() {
    guard let tab = focusedWorkspaceContentTab ?? activeWorkspaceContentTab else { return }
    closeWorkspaceTab(tab.id)
  }

  func closeWorkspaceTab(_ id: String) {
    guard let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
    if case .file = tab, let session = fileTabWorkspaces[id],
      session.selectedFileEditor?.hasUnsavedChanges == true {
      guard pendingWorkspaceTabCloses[id] == nil else { return }
      let request = UUID(); pendingWorkspaceTabCloses[id] = request
      Task { [weak self] in
        let saved = await session.saveSelectedFileEdits()
        guard let self, pendingWorkspaceTabCloses[id] == request else { return }
        pendingWorkspaceTabCloses[id] = nil
        guard saved, !shuttingDown, workspaceTabs.contains(tab), fileTabWorkspaces[id] === session else { return }
        closeWorkspaceTab(id)
      }
      return
    }
    if tab.kind == .file { closedFilePlacements[tab.id] = workspaceTabPlacement(tab.id) }
    if tab.kind == .pullRequest || tab.kind == .pullRequestWatch || tab.kind == .backgroundTerminal || tab.kind == .subagents { closedPullRequestPlacements[tab.id] = workspaceTabPlacement(tab.id) }
    switch tab {
    case .browser(let browserID, _): workspace.browser.close(browserID)
    case .file, .review, .plan, .sources, .pullRequest, .pullRequestWatch, .backgroundTerminal, .subagents:
      pullRequestTabPresentations.clear(tab.id)
      closedWorkspaceTabs.append(tab)
      trimClosedWorkspaceTabs()
      workspaceTabDidDisappear(tab)
    case .terminal(let terminalID, _):
      if let scope = terminalScope(for: tab) {
        workspace.terminals.close(terminalID, for: scope)
      }
      closedWorkspaceTabs.append(tab)
      trimClosedWorkspaceTabs()
      workspaceTabDidDisappear(tab)
    }
  }

  func moveWorkspaceTab(_ id: String, to placement: WorkspaceTabPlacement) {
    guard canMoveWorkspaceTab(id, to: placement),
      let tab = visibleWorkspaceContentTabs.first(where: { $0.id == id }) else { return }
    let oldPlacement = workspaceTabPlacement(id)
    if ContentTabClosePanel(oldPlacement, id: id) != ContentTabClosePanel(placement, id: id) {
      recordWorkspaceTabMoved(tab)
    }
    if placement == .left { workspaceContentLayoutMode = .full; showingInspector = false }
    else if placement == .right {
      workspaceContentLayoutMode = .split
      activeWorkspaceTabID = nil
    }
    guard oldPlacement != placement else { activateWorkspaceTab(id); return }
    workspaceTabPlacements[id] = placement
    if activeWorkspaceTabID == id { activeWorkspaceTabID = nil }
    if activeRightWorkspaceTabID == id { activeRightWorkspaceTabID = nil }
    if activeBottomWorkspaceTabID == id { activeBottomWorkspaceTabID = nil }
    switch placement {
    case .left:
      activeWorkspaceTabID = id
    case .right:
      activeRightWorkspaceTabID = id
      showingInspector = true
    case .bottom:
      activeBottomWorkspaceTabID = id
      showingTerminal = true
    case .detached:
      break
    }
    if oldPlacement == .right && placement != .right
      && visibleWorkspaceContentTabs(in: .right).isEmpty {
      pane = "execution"
    }
    focusedWorkspaceTabID = id
    lastWorkspaceContentTabID = id
    recordWorkspaceTabSelection(tab)
    if case .browser(let browserID, _) = tab, workspace.browser.selection != browserID {
      workspace.browser.select(browserID)
    }
    if tab.terminalID != nil { focusTerminal(tab.terminalID) }
  }

  func canMoveWorkspaceTab(_ id: String, to placement: WorkspaceTabPlacement) -> Bool {
    guard let tab = visibleWorkspaceContentTabs.first(where: { $0.id == id }) else {
      return false
    }
    return placement != .bottom || tab.terminalID != nil
  }

  func beginWorkspaceTabDrag(_ id: String) {
    guard visibleWorkspaceContentTabs.contains(where: { $0.id == id }) else { return }
    let sessionID = UUID()
    workspaceTabDragSessionID = sessionID
    draggingWorkspaceTabID = id
    workspaceTabDropTarget = nil
  }

  func endWorkspaceTabDrag(session: UUID? = nil) {
    if let session, session != workspaceTabDragSessionID { return }
    workspaceTabDragSessionID = nil
    draggingWorkspaceTabID = nil
    workspaceTabDropTarget = nil
  }

  func canDropWorkspaceTab(to placement: WorkspaceTabPlacement) -> Bool {
    destination == .workspace && draggingWorkspaceTabID.map { canMoveWorkspaceTab($0, to: placement) } == true
  }

  @discardableResult func dropWorkspaceTab(_ values: [String], to placement: WorkspaceTabPlacement) -> Bool {
    defer { endWorkspaceTabDrag() }
    guard destination == .workspace,
      let id = values.compactMap(WorkspaceTabDragToken.decode).first,
      canMoveWorkspaceTab(id, to: placement) else { return false }
    moveWorkspaceTab(id, to: placement)
    return true
  }

  func workspaceTabTransferCandidate(_ source: WorkspaceContentTab, toOwner newOwner: String) -> WorkspaceContentTab? {
    guard source.owner != newOwner else { return source }
    guard newOwner == "new:none" || newOwner.hasPrefix("new:/") || library.tasks.contains(where: { $0.id == newOwner }) else {
      error = "目标任务已移除，未移动标签。"; return nil
    }
    let migrated: WorkspaceContentTab
    switch source {
    case .browser(let browserID, _): migrated = .browser(browserID, owner: newOwner)
    case .file(let path, _):
      guard fileTabWorkspaces[source.id]?.selectedFileEditor?.hasUnsavedChanges != true else {
        error = "请先保存文件更改，再移动标签。"; return nil
      }
      guard let root = workspaceTabProject(owner: newOwner) else {
        error = "文件不在目标任务的项目中。"; return nil
      }
      if path.isEmpty { migrated = .file(path, owner: newOwner) }
      else {
        guard let sourceRoot = workspaceTabProject(owner: source.owner),
          let original = try? WorkspaceFileScope.location(path,
            roots: WorkspaceFileScope.roots(primary: sourceRoot, additional: additionalWorkspaceFolders(for: sourceRoot))),
          let destination = try? WorkspaceFileScope.location(original.url.path,
            roots: WorkspaceFileScope.roots(primary: root, additional: additionalWorkspaceFolders(for: root))) else {
          error = "文件不在目标任务的项目中。"; return nil
        }
        migrated = .file(WorkspaceFileScope.key(destination, primary: root), owner: newOwner)
      }
    case .review: migrated = .review(owner: newOwner)
    case .subagents:
      error = "子任务属于原会话，不能移到其他任务。"
      return nil
    case .backgroundTerminal:
      error = "后台终端输出属于原任务，不能移到其他任务。"
      return nil
    case .plan:
      error = "计划文档属于原任务，不能移到其他任务。"
      return nil
    case .sources:
      error = "来源属于原任务，不能移到其他任务。"
      return nil
    case .pullRequest:
      error = "PR 详情属于原任务，不能移到其他任务。"
      return nil
    case .pullRequestWatch:
      error = "PR 监控进度属于原任务，不能移到其他任务。"
      return nil
    case .terminal(let terminalID, _):
      guard terminalScope(for: source) != nil, terminalSession(terminalID) != nil else {
        error = "终端已不可用，未移动标签。"; return nil
      }
      migrated = .terminal(terminalID, owner: newOwner)
    }
    guard !workspaceTabs.contains(where: { $0.id == migrated.id && $0.id != source.id }) else {
      error = "目标聊天已经包含此类标签。"
      return nil
    }
    return migrated
  }

  @discardableResult func moveWorkspaceTab(_ id: String, toOwner newOwner: String) -> String? {
    guard let source = workspaceTabs.first(where: { $0.id == id }),
      let migrated = workspaceTabTransferCandidate(source, toOwner: newOwner) else { return nil }
    guard source.owner != newOwner else { return source.id }
    if let terminalID = source.terminalID {
      guard let sourceScope = terminalScope(for: source) else { return nil }
      let destinationScope = TerminalScope(root: sourceScope.root, conversation: newOwner)
      guard workspace.terminals.move(terminalID, from: sourceScope, to: destinationScope) else {
        return nil
      }
    }
    let placement = workspaceTabPlacement(source.id)
    workspaceTabDidDisappear(source, transferring: true)
    workspaceTabs.append(migrated)
    workspaceTabPlacements[migrated.id] = placement
    migrateWorkspaceTabState(from: source.id, to: migrated.id, owner: newOwner)
    recordReceivedWorkspaceTab(migrated)
    saveLibrary()
    return migrated.id
  }

  @discardableResult func moveWorkspaceTab(_ id: String, toTaskID taskID: String) async -> Bool {
    guard let target = library.tasks.first(where: { $0.id == taskID }),
      let source = workspaceTabs.first(where: { $0.id == id }),
      workspaceTabTransferCandidate(source, toOwner: taskID) != nil else { return false }
    if currentProjectKey != target.project {
      guard await openTaskScope(target.project) else { return false }
    }
    guard let current = library.tasks.first(where: { $0.id == taskID }), current.project == target.project,
      workspaceTabs.contains(source),
      let migratedID = moveWorkspaceTab(id, toOwner: taskID)
    else { return false }
    applyTaskSelection(current)
    activateWorkspaceTab(migratedID)
    endWorkspaceTabDrag()
    return true
  }

  @discardableResult func moveWorkspaceTabToNewTask(_ id: String) async -> Bool {
    let futureOwner = "new:\(project == nil ? "none" : currentDraftProjectKey)"
    guard let source = workspaceTabs.first(where: { $0.id == id }),
      workspaceTabTransferCandidate(source, toOwner: futureOwner) != nil else { return false }
    let targetProject = currentProjectKey
    await newChat()
    guard selectedTask == nil, currentProjectKey == targetProject, workspaceTabs.contains(source),
      let migratedID = moveWorkspaceTab(id, toOwner: draftKey)
    else { return false }
    activateWorkspaceTab(migratedID)
    endWorkspaceTabDrag()
    return true
  }

  private func migrateWorkspaceTabState(from oldID: String, to newID: String, owner: String) {
    if oldID != newID, let session = fileTabWorkspaces.removeValue(forKey: oldID) {
      fileTabWorkspaces[newID] = session
    }
    if oldID != newID, let placement = workspaceTabPlacements.removeValue(forKey: oldID) {
      workspaceTabPlacements[newID] = placement
    }
    activeWorkspaceTabID = activeWorkspaceTabID == oldID ? newID : activeWorkspaceTabID
    activeRightWorkspaceTabID = activeRightWorkspaceTabID == oldID ? newID : activeRightWorkspaceTabID
    activeBottomWorkspaceTabID =
      activeBottomWorkspaceTabID == oldID ? newID : activeBottomWorkspaceTabID
    focusedWorkspaceTabID = focusedWorkspaceTabID == oldID ? newID : focusedWorkspaceTabID
    lastWorkspaceContentTabID = lastWorkspaceContentTabID == oldID ? newID : lastWorkspaceContentTabID
    for index in library.pinnedContentTabs.indices
      where library.pinnedContentTabs[index].sourceWindowID == nil && library.pinnedContentTabs[index].sourceTabID == oldID {
      library.pinnedContentTabs[index].sourceTabID = newID
      library.pinnedContentTabs[index].owner = owner
    }
  }

  func closeOtherWorkspaceTabs(keeping id: String?) {
    let placement = id.map(workspaceTabStripPlacement) ?? .left
    for tab in presentedWorkspaceContentTabs(in: placement).reversed() where tab.id != id {
      closeWorkspaceTab(tab.id)
    }
    activateWorkspaceTab(id)
  }

  func closeWorkspaceTabsToRight(of id: String?) {
    let placement = id.map(workspaceTabStripPlacement) ?? .left
    let prefix: [String?] = placement == .left ? [nil] : []
    let ids = prefix + presentedWorkspaceContentTabs(in: placement).map { Optional($0.id) }
    guard let index = ids.firstIndex(where: { $0 == id }), index + 1 < ids.count else { return }
    for candidate in ids[(index + 1)...].reversed() {
      if let candidate { closeWorkspaceTab(candidate) }
    }
    activateWorkspaceTab(id)
  }

  func canCloseWorkspaceTabsToRight(of id: String?) -> Bool {
    let placement = id.map(workspaceTabStripPlacement) ?? .left
    let prefix: [String?] = placement == .left ? [nil] : []
    let ids = prefix + presentedWorkspaceContentTabs(in: placement).map { Optional($0.id) }
    guard let index = ids.firstIndex(where: { $0 == id }) else { return false }
    return index + 1 < ids.count
  }

  @discardableResult func reorderWorkspaceTab(_ source: String, relativeTo target: String,
    after: Bool) -> Bool {
    guard source != target,
      visibleWorkspaceContentTabs.contains(where: { $0.id == source }),
      visibleWorkspaceContentTabs.contains(where: { $0.id == target }),
      workspaceTabStripPlacement(source) == workspaceTabStripPlacement(target),
      let sourceIndex = workspaceTabs.firstIndex(where: { $0.id == source }),
      workspaceTabs.contains(where: { $0.id == target }) else { return false }
    let tab = workspaceTabs.remove(at: sourceIndex)
    guard let targetIndex = workspaceTabs.firstIndex(where: { $0.id == target }) else {
      workspaceTabs.insert(tab, at: min(sourceIndex, workspaceTabs.count))
      return false
    }
    workspaceTabs.insert(tab, at: targetIndex + (after ? 1 : 0))
    recordWorkspaceTabMoved(tab)
    return true
  }

  @discardableResult func reorderWorkspaceTab(_ id: String, horizontalTranslation: CGFloat,
    sourceWidth: CGFloat) -> Bool {
    let tabs = presentedWorkspaceContentTabs(in: workspaceTabStripPlacement(id))
    guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }), sourceWidth > 0,
      abs(horizontalTranslation) >= max(12, sourceWidth * 0.35) else { return false }
    let direction = horizontalTranslation > 0 ? 1 : -1
    let stepWidth = sourceWidth + 2
    let steps = max(1, Int((abs(horizontalTranslation) + stepWidth / 2) / stepWidth))
    let targetIndex = min(max(0, sourceIndex + direction * steps), tabs.count - 1)
    guard targetIndex != sourceIndex else { return false }
    return reorderWorkspaceTab(id, relativeTo: tabs[targetIndex].id, after: direction > 0)
  }

  func reopenClosedWorkspaceTab() {
    let owner = currentWorkspaceTabOwner
    guard let index = closedWorkspaceTabs.lastIndex(where: { tab in
      tab.owner == owner && (tab.browserID.map { workspace.browser.canReopenClosedTab($0) } ?? true)
    }) else { return }
    let tab = closedWorkspaceTabs.remove(at: index)
    switch tab {
    case .file(let path, let owner):
      let placement = closedFilePlacements.removeValue(forKey: tab.id) ?? .left
      if owner == currentWorkspaceTabOwner { _ = openFileTab(path, in: placement) }
    case .review:
      if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
      if tab.owner == currentWorkspaceTabOwner { activateWorkspaceTab(tab.id) }
    case .plan(let runID, let owner):
      if owner == currentWorkspaceTabOwner { _ = openPlanDocument(runID: runID) }
    case .sources(let owner):
      if owner == currentWorkspaceTabOwner { _ = openTaskSources() }
    case .pullRequest(_, let owner):
      let placement = closedPullRequestPlacements.removeValue(forKey: tab.id) ?? .right
      if owner == currentWorkspaceTabOwner, let request = pullRequestContent(tab) {
        _ = openPullRequestContent(request, in: placement == .detached ? .right : placement)
      }
    case .pullRequestWatch:
      let placement = closedPullRequestPlacements.removeValue(forKey: tab.id) ?? .right
      if tab.owner == currentWorkspaceTabOwner, let watch = pullRequestWatchContent(tab) {
        _ = openPullRequestWatchProgress(watch, in: placement == .detached ? .right : placement)
      }
    case .browser(let originalID, let owner):
      reopeningWorkspaceTabOwner = owner
      _ = workspace.browser.reopenClosedTab(originalID: originalID)
      reopeningWorkspaceTabOwner = nil
    case .subagents(let owner):
      let placement = closedPullRequestPlacements.removeValue(forKey: tab.id) ?? .right
      if owner == currentWorkspaceTabOwner { _ = openSubagents(in: placement == .detached ? .right : placement) }
    case .backgroundTerminal(let id, let owner):
      let placement = closedPullRequestPlacements.removeValue(forKey: tab.id) ?? .right
      if owner == currentWorkspaceTabOwner { _ = openBackgroundTerminal(id, in: placement == .detached ? .right : placement) }
    case .terminal(_, let owner):
      guard owner == currentWorkspaceTabOwner else { return }
      newTerminalTab(in: .bottom)
    }
  }

  var canReopenClosedWorkspaceTab: Bool {
    closedWorkspaceTabs.contains { tab in
      tab.owner == currentWorkspaceTabOwner &&
        (tab.browserID.map { workspace.browser.canReopenClosedTab($0) } ?? true)
    }
  }

  func workspaceBrowserDidOpen(_ id: UUID) {
    let owner = reopeningWorkspaceTabOwner ?? currentWorkspaceTabOwner
    let tab = WorkspaceContentTab.browser(id, owner: owner)
    if !workspaceTabs.contains(where: { $0.id == tab.id }) { workspaceTabs.append(tab) }
  }

  func workspaceBrowserDidSelect(_ id: UUID) {
    guard !synchronizingWorkspaceBrowserSelection else { return }
    guard let tab = workspaceTabs.first(where: { $0.browserID == id }),
      tab.owner == currentWorkspaceTabOwner else { return }
    recordWorkspaceTabSelection(tab)
    switch workspaceTabPlacement(tab.id) {
    case .left, .right:
      selectWorkspacePrimaryContent(tab)
    case .bottom: break
    case .detached: break
    }
    focusedWorkspaceTabID = tab.id
    lastWorkspaceContentTabID = tab.id
  }

  func workspaceBrowserDidClose(_ id: UUID) {
    guard let tab = workspaceTabs.first(where: { $0.browserID == id }) else { return }
    closedWorkspaceTabs.append(tab)
    trimClosedWorkspaceTabs()
    workspaceTabDidDisappear(tab)
    if !shuttingDown {
      library.workspaceTabLayouts[tab.owner]?.tabs.removeAll { $0.id == tab.id }
      restoredDetachedWorkspaceTabIDs.removeAll { $0 == tab.id }
      saveLibrary()
    }
  }

  func workspaceBrowserDidReorder(_ ids: [UUID]) {
    let browserTabs = Dictionary(
      workspaceTabs.compactMap { tab in tab.browserID.map { ($0, tab) } },
      uniquingKeysWith: { first, _ in first })
    var remaining = ids
    for index in workspaceTabs.indices where workspaceTabs[index].browserID != nil {
      guard let id = remaining.first,
        let replacement = browserTabs[id] else { continue }
      workspaceTabs[index] = replacement
      remaining.removeFirst()
    }
  }

  private func trimClosedWorkspaceTabs() {
    if closedWorkspaceTabs.count > 20 {
      closedWorkspaceTabs.removeFirst(closedWorkspaceTabs.count - 20)
    }
    let ids = Set(closedWorkspaceTabs.map(\.id))
    closedFilePlacements = closedFilePlacements.filter { ids.contains($0.key) }
    closedPullRequestPlacements = closedPullRequestPlacements.filter { ids.contains($0.key) }
  }

  func moveWorkspaceTabs(from oldOwner: String, to newOwner: String) {
    guard oldOwner != newOwner else { return }
    var migratedIDs: [String: String] = [:]
    workspaceTabs = workspaceTabs.map { tab in
      guard tab.owner == oldOwner else { return tab }
      let migrated: WorkspaceContentTab
      switch tab {
      case .browser(let id, _): migrated = .browser(id, owner: newOwner)
      case .file(let path, _): migrated = .file(path, owner: newOwner)
      case .review: migrated = .review(owner: newOwner)
      case .plan(let runID, _): migrated = .plan(runID, owner: newOwner)
      case .sources: migrated = .sources(owner: newOwner)
      case .subagents: migrated = .subagents(owner: newOwner)
      case .pullRequest(let url, _): migrated = .pullRequest(url, owner: newOwner)
      case .pullRequestWatch(let id, let target, _): migrated = .pullRequestWatch(id, task: target, owner: newOwner)
      case .backgroundTerminal(let id, _): migrated = .backgroundTerminal(id, owner: newOwner)
      case .terminal(let id, _): migrated = .terminal(id, owner: newOwner)
      }
      migratedIDs[tab.id] = migrated.id
      return migrated
    }
    for (oldID, newID) in migratedIDs {
      migrateWorkspaceTabState(from: oldID, to: newID, owner: newOwner)
    }
    for (scope, var controller) in workspaceTabCloseControllers where scope.owner == oldOwner {
      controller.rekey(migratedIDs)
      let panel: ContentTabClosePanel
      if case .detached(let id) = scope.panel { panel = .detached(migratedIDs[id] ?? id) }
      else { panel = scope.panel }
      workspaceTabCloseControllers[.init(owner: newOwner, panel: panel)] = controller
      workspaceTabCloseControllers[scope] = nil
    }
    for index in library.pinnedContentTabs.indices
      where library.pinnedContentTabs[index].sourceWindowID == nil && library.pinnedContentTabs[index].owner == oldOwner {
      library.pinnedContentTabs[index].owner = newOwner
    }
  }
}
