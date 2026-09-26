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

  var activeWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeWorkspaceTabID else { return nil }
    return visibleWorkspaceContentTabs(in: .left).first { $0.id == activeWorkspaceTabID }
  }


  var activeRightWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeRightWorkspaceTabID else { return nil }
    return visibleWorkspaceContentTabs(in: .right).first { $0.id == activeRightWorkspaceTabID }
  }

  var activeBottomWorkspaceContentTab: WorkspaceContentTab? {
    guard let activeBottomWorkspaceTabID else { return nil }
    return visibleWorkspaceContentTabs(in: .bottom).first { $0.id == activeBottomWorkspaceTabID }
  }

  var focusedWorkspaceContentTab: WorkspaceContentTab? {
    guard let focusedWorkspaceTabID else { return nil }
    return visibleWorkspaceContentTabs.first { $0.id == focusedWorkspaceTabID }
  }

  var activeBrowserTabID: UUID? { activeWorkspaceContentTab?.browserID }

  func workspaceTabTitle(_ tab: WorkspaceContentTab) -> String {
    switch tab {
    case .browser(let id, _):
      return workspace.browser.tabs.first(where: { $0.id == id })?.title ?? "浏览器"
    case .review: return "审查"
    case .plan(let runID, let owner):
      return taskWindowRuns(owner).first(where: { $0.id == runID })?.codexPlanDocument?.title ?? "计划"
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
    case .review(let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .review,
        title: "审查", restoreURL: nil)
    case .plan(_, let owner):
      reference = PinnedWorkspaceTab(
        id: UUID().uuidString, sourceTabID: tab.id, owner: owner, kind: .plan,
        title: workspaceTabTitle(tab), restoreURL: nil)
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
    switch workspaceTabPlacement(tab.id) {
    case .left:
      activeWorkspaceTabID = tab.id
    case .right:
      activeRightWorkspaceTabID = tab.id
      showingInspector = true
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
      if workspace.browser.selection != browserID { workspace.browser.select(browserID) }
    case .review:
      Task { await workspace.refreshGit() }
    case .plan: break
    case .terminal:
      focusTerminal()
    }
  }

  func focusWorkspaceTab(at index: Int) {
    let ids: [String?] = [nil] + visibleWorkspaceContentTabs.map { Optional($0.id) }
    guard ids.indices.contains(index) else { return }
    activateWorkspaceTab(ids[index])
  }

  func moveWorkspaceTab(_ offset: Int) {
    let ids: [String?] = [nil] + visibleWorkspaceContentTabs.map { Optional($0.id) }
    guard ids.count > 1 else { return }
    let current = ids.firstIndex { $0 == activeWorkspaceTabID } ?? 0
    activateWorkspaceTab(ids[(current + offset + ids.count) % ids.count])
  }

  func openReviewTab() {
    openReviewTab(in: .left)
  }

  func openReviewTab(in placement: WorkspaceTabPlacement) {
    guard project != nil else { return }
    let tab = WorkspaceContentTab.review(owner: currentWorkspaceTabOwner)
    if !workspaceTabs.contains(tab) {
      workspaceTabs.append(tab)
      workspace.reviewScope = library.gitPreferences.defaultReviewScope
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

  func closeActiveWorkspaceTab() {
    guard let tab = focusedWorkspaceContentTab ?? activeWorkspaceContentTab else { return }
    closeWorkspaceTab(tab.id)
  }

  func closeWorkspaceTab(_ id: String) {
    guard let tab = workspaceTabs.first(where: { $0.id == id }) else { return }
    switch tab {
    case .browser(let browserID, _): workspace.browser.close(browserID)
    case .review, .plan:
      closedWorkspaceTabs.append(tab)
      trimClosedWorkspaceTabs()
      workspaceTabs.removeAll { $0.id == id }
      workspaceTabDidDisappear(id)
    case .terminal(let terminalID, _):
      if let scope = terminalScope(for: tab) {
        workspace.terminals.close(terminalID, for: scope)
      }
      closedWorkspaceTabs.append(tab)
      trimClosedWorkspaceTabs()
      workspaceTabs.removeAll { $0.id == id }
      workspaceTabDidDisappear(id)
    }
  }

  func moveWorkspaceTab(_ id: String, to placement: WorkspaceTabPlacement) {
    guard canMoveWorkspaceTab(id, to: placement),
      let tab = visibleWorkspaceContentTabs.first(where: { $0.id == id }) else { return }
    let oldPlacement = workspaceTabPlacement(id)
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

  @discardableResult func moveWorkspaceTab(_ id: String, toOwner newOwner: String) -> String? {
    guard let index = workspaceTabs.firstIndex(where: { $0.id == id }) else { return nil }
    let source = workspaceTabs[index]
    guard source.owner != newOwner else { return source.id }
    let migrated: WorkspaceContentTab
    switch source {
    case .browser(let browserID, _): migrated = .browser(browserID, owner: newOwner)
    case .review: migrated = .review(owner: newOwner)
    case .plan:
      error = "计划文档属于原任务，不能移到其他任务。"
      return nil
    case .terminal(let terminalID, _): migrated = .terminal(terminalID, owner: newOwner)
    }
    guard !workspaceTabs.contains(where: { $0.id == migrated.id && $0.id != source.id }) else {
      error = "目标聊天已经包含此类标签。"
      return nil
    }
    if let terminalID = source.terminalID {
      guard let sourceScope = terminalScope(for: source) else { return nil }
      let destinationScope = TerminalScope(root: sourceScope.root, conversation: newOwner)
      guard workspace.terminals.move(terminalID, from: sourceScope, to: destinationScope) else {
        return nil
      }
    }
    workspaceTabs[index] = migrated
    migrateWorkspaceTabState(from: source.id, to: migrated.id, owner: newOwner)
    saveLibrary()
    return migrated.id
  }

  @discardableResult func moveWorkspaceTab(_ id: String, toTaskID taskID: String) async -> Bool {
    guard let target = library.tasks.first(where: { $0.id == taskID }) else { return false }
    if currentProjectKey != target.project {
      guard await openTaskScope(target.project) else { return false }
    }
    guard let current = library.tasks.first(where: { $0.id == taskID }),
      let migratedID = moveWorkspaceTab(id, toOwner: taskID)
    else { return false }
    applyTaskSelection(current)
    activateWorkspaceTab(migratedID)
    endWorkspaceTabDrag()
    return true
  }

  @discardableResult func moveWorkspaceTabToNewTask(_ id: String) async -> Bool {
    guard workspaceTabs.contains(where: { $0.id == id }) else { return false }
    await newProjectlessTask()
    guard selectedTask == nil, currentProjectKey.isEmpty,
      let migratedID = moveWorkspaceTab(id, toOwner: draftKey)
    else { return false }
    activateWorkspaceTab(migratedID)
    endWorkspaceTabDrag()
    return true
  }

  private func migrateWorkspaceTabState(from oldID: String, to newID: String, owner: String) {
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

  private func workspaceTabDidDisappear(_ id: String) {
    if draggingWorkspaceTabID == id { endWorkspaceTabDrag() }
    workspaceTabPlacements[id] = nil
    if activeWorkspaceTabID == id { activeWorkspaceTabID = nil }
    if activeRightWorkspaceTabID == id { activeRightWorkspaceTabID = nil }
    if activeBottomWorkspaceTabID == id { activeBottomWorkspaceTabID = nil }
    if focusedWorkspaceTabID == id { focusedWorkspaceTabID = nil }
  }

  func closeOtherWorkspaceTabs(keeping id: String?) {
    let placement = id.map(workspaceTabPlacement) ?? .left
    for tab in visibleWorkspaceContentTabs(in: placement).reversed() where tab.id != id {
      closeWorkspaceTab(tab.id)
    }
    activateWorkspaceTab(id)
  }

  func closeWorkspaceTabsToRight(of id: String?) {
    let placement = id.map(workspaceTabPlacement) ?? .left
    let prefix: [String?] = placement == .left ? [nil] : []
    let ids = prefix + visibleWorkspaceContentTabs(in: placement).map { Optional($0.id) }
    guard let index = ids.firstIndex(where: { $0 == id }), index + 1 < ids.count else { return }
    for candidate in ids[(index + 1)...].reversed() {
      if let candidate { closeWorkspaceTab(candidate) }
    }
    activateWorkspaceTab(id)
  }

  func canCloseWorkspaceTabsToRight(of id: String?) -> Bool {
    let placement = id.map(workspaceTabPlacement) ?? .left
    let prefix: [String?] = placement == .left ? [nil] : []
    let ids = prefix + visibleWorkspaceContentTabs(in: placement).map { Optional($0.id) }
    guard let index = ids.firstIndex(where: { $0 == id }) else { return false }
    return index + 1 < ids.count
  }

  @discardableResult func reorderWorkspaceTab(_ source: String, relativeTo target: String,
    after: Bool) -> Bool {
    guard source != target,
      let sourceIndex = workspaceTabs.firstIndex(where: { $0.id == source }),
      workspaceTabs.contains(where: { $0.id == target }) else { return false }
    let tab = workspaceTabs.remove(at: sourceIndex)
    guard let targetIndex = workspaceTabs.firstIndex(where: { $0.id == target }) else {
      workspaceTabs.insert(tab, at: min(sourceIndex, workspaceTabs.count))
      return false
    }
    workspaceTabs.insert(tab, at: targetIndex + (after ? 1 : 0))
    return true
  }

  @discardableResult func reorderWorkspaceTab(_ id: String, horizontalTranslation: CGFloat,
    sourceWidth: CGFloat) -> Bool {
    let tabs = visibleWorkspaceContentTabs(in: workspaceTabPlacement(id))
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
    guard let tab = closedWorkspaceTabs.popLast() else { return }
    switch tab {
    case .review:
      if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
      if tab.owner == currentWorkspaceTabOwner { activateWorkspaceTab(tab.id) }
    case .plan(let runID, let owner):
      if owner == currentWorkspaceTabOwner { _ = openPlanDocument(runID: runID) }
    case .browser(_, let owner):
      reopeningWorkspaceTabOwner = owner
      _ = workspace.browser.reopenClosedTab()
      reopeningWorkspaceTabOwner = nil
    case .terminal(_, let owner):
      guard owner == currentWorkspaceTabOwner else { return }
      newTerminalTab(in: .bottom)
    }
  }

  var canReopenClosedWorkspaceTab: Bool { !closedWorkspaceTabs.isEmpty }

  func workspaceBrowserDidOpen(_ id: UUID) {
    let owner = reopeningWorkspaceTabOwner ?? currentWorkspaceTabOwner
    let tab = WorkspaceContentTab.browser(id, owner: owner)
    if !workspaceTabs.contains(where: { $0.id == tab.id }) { workspaceTabs.append(tab) }
  }

  func workspaceBrowserDidSelect(_ id: UUID) {
    guard let tab = workspaceTabs.first(where: { $0.browserID == id }),
      tab.owner == currentWorkspaceTabOwner else { return }
    switch workspaceTabPlacement(tab.id) {
    case .left: activeWorkspaceTabID = tab.id
    case .right:
      activeRightWorkspaceTabID = tab.id
      showingInspector = true
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
    workspaceTabs.removeAll { $0.id == tab.id }
    workspaceTabDidDisappear(tab.id)
    if !shuttingDown {
      library.workspaceTabLayouts[tab.owner]?.tabs.removeAll { $0.id == tab.id }
      restoredDetachedWorkspaceTabIDs.removeAll { $0 == tab.id }
      saveLibrary()
    }
    if destination == .workspace && tab.owner == currentWorkspaceTabOwner { focusComposer = UUID() }
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
  }

  func moveWorkspaceTabs(from oldOwner: String, to newOwner: String) {
    guard oldOwner != newOwner else { return }
    var migratedIDs: [String: String] = [:]
    workspaceTabs = workspaceTabs.map { tab in
      guard tab.owner == oldOwner else { return tab }
      let migrated: WorkspaceContentTab
      switch tab {
      case .browser(let id, _): migrated = .browser(id, owner: newOwner)
      case .review: migrated = .review(owner: newOwner)
      case .plan(let runID, _): migrated = .plan(runID, owner: newOwner)
      case .terminal(let id, _): migrated = .terminal(id, owner: newOwner)
      }
      migratedIDs[tab.id] = migrated.id
      return migrated
    }
    for (oldID, newID) in migratedIDs {
      migrateWorkspaceTabState(from: oldID, to: newID, owner: newOwner)
    }
    for index in library.pinnedContentTabs.indices
      where library.pinnedContentTabs[index].sourceWindowID == nil && library.pinnedContentTabs[index].owner == oldOwner {
      library.pinnedContentTabs[index].owner = newOwner
    }
  }
}
