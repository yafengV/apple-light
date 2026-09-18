import AppKit

extension WorkspaceStore {
  func executeCommand(_ id: String) {
    guard commandEnabled(id) else { return }
    showingCommands = false
    switch id {
    case "approval-approve": resolveActiveMCPApproval(taskID: selectedTask?.id, decision: .allowOnce)
    case "approval-decline": resolveActiveMCPApproval(taskID: selectedTask?.id, decision: .deny)
    case "new", "new-alternate": Task { await newProjectlessTask() }
    case "palette", "palette-alternate": showingCommands = true
    case "shortcuts": openSettings(.shortcuts)
    case "model": openModelPicker()
    case "branch": openBranchPicker()
    case "fork": forkConversation()
    case "plan":
      action = .chat
      chatMode = .plan
      focusComposer = UUID()
    case "sidebar": NotificationCenter.default.post(name: .toggleShipiOSSidebar, object: nil)
    case "send": Task { await sendDraft() }
    case "find-next": moveFindMatch(1)
    case "find-previous": moveFindMatch(-1)
    case "previous-task": adjacentTaskOrTab(-1)
    case "next-task": adjacentTaskOrTab(1)
    case "next-attention": Task { await openNextAttentionTask() }
    case "clear-unread": clearUnreadTasks()
    case "back": Task { await navigate(back: true) }
    case "forward": Task { await navigate(back: false) }
    case "bottom-panel":
      toggleBottomPanel()
    case "search": showingSearch = true
    case "projects": showProjects()
    case "plugins": showPlugins()
    case "automations": showAutomations()
    case "settings": openSettings()
    case "pet": togglePet()
    case "open": chooseProject()
    case "files":
      destination = .workspace
      showingFileSearch = true
    case "tree": togglePane("files")
    case "terminal":
      toggleTerminalPanel()
    case "review": togglePane("review")
    case "review-open": openReviewTab()
    case "browser":
      if activeBrowserTabID != nil { activateChatTab() }
      else if let tab = visibleWorkspaceContentTabs.first(where: { $0.browserID != nil }) {
        activateWorkspaceTab(tab.id)
      } else { newBrowserTab() }
    case "browser-new": newBrowserTab()
    case "browser-address":
      if filesVisible { workspace.showingFileLine = true }
      else { performBrowserCommand(id) }
    case "browser-back", "browser-forward", "browser-reload", "browser-reload-origin", "browser-copy", "browser-close",
      "browser-reopen":
      performBrowserCommand(id)
    case "tab-close": closeActiveWorkspaceTab()
    case "tab-close-others": closeOtherWorkspaceTabs(keeping: activeWorkspaceTabID)
    case "workspace-tabs": toggleWorkspaceTabVisibility()
    case "workspace-view": toggleWorkspaceTabView()
    case "workspace-swap-panes": swapWorkspacePanes()
    case let value where value.hasPrefix("focus-tab-"):
      if let index = Int(value.dropFirst("focus-tab-".count)) { focusWorkspaceTab(at: index - 1) }
    case let value where value.hasPrefix("focus-chat-"):
      if let slot = DesktopCommand.numberSlot(value), let task = numberedSidebarTask(at: slot.index) {
        selectTask(task)
      }
    case "find":
      if destination == .settings {
        settingsSearchFocusRequest = UUID()
      } else {
        destination = .workspace
        showingFind = true
      }
    case "rename": if let id = selectedTask?.id { beginRenamingTask(id) }
    case "pin": if let t = selectedTask { updateTask(t.id, pin: !t.pinned) }
    case "unread":
      if let t = selectedTask { setTaskUnread(t.id, unread: true) }
    case "archive": if let t = selectedTask { updateTask(t.id, archive: true) }
    case "doctor": Task { await start("doctor") }
    case "build": Task { await start("build") }
    case "stop": Task { await cancel() }
    default: break
    }
  }
  func commandEnabled(_ id: String) -> Bool {
    guard renameTaskID == nil, !restoringLibrary, !hasSettingsConfirmation, presentedOverlay != .imagePreview, presentedOverlay != .fileSearch else { return false }
    switch id {
    case "approval-approve", "approval-decline":
      return destination == .workspace && activeWorkspaceContentTab == nil
        && activeMCPApproval(taskID: selectedTask?.id) != nil
    case "next-attention": return nextAttentionTask != nil
    case "clear-unread": return libraryLoaded && !library.unreadTasks.isEmpty
    case "send": return canSend
    case "branch": return canChangeBranch && workspace.gitAvailable
    case "browser-address": return (filesVisible && workspace.selectedFile != nil && !workspace.fileLoading && workspace.fileError == nil)
      || (browserVisible && workspace.browser.selected != nil)
    case "browser-close": return activeBrowserTabID != nil
      || (showingInspector && pane == "browser" && workspace.browser.selected != nil)
    case "browser-reopen": return canReopenClosedWorkspaceTab
    case "browser-back": return browserVisible && workspace.browser.selected?.canGoBack == true
    case "browser-forward": return browserVisible && workspace.browser.selected?.canGoForward == true
    case "browser-reload", "browser-reload-origin": return browserVisible && workspace.browser.selected != nil
    case "browser-copy": return browserVisible && workspace.browser.selected?.committedURL != nil
    case "fork": return destination == .workspace && canForkConversation
    case "tab-close": return destination == .workspace && focusedWorkspaceContentTab != nil
    case "tab-close-others": return destination == .workspace
      && !visibleWorkspaceContentTabs.isEmpty
    case "workspace-tabs", "workspace-view": return destination == .workspace
    case "workspace-swap-panes": return destination == .workspace && showingInspector
    case let value where value.hasPrefix("focus-tab-"):
      guard destination == .workspace,
        let slot = DesktopCommand.numberSlot(value) else { return false }
      return slot.index <= visibleWorkspaceContentTabs.count + 1
    case let value where value.hasPrefix("focus-chat-"):
      guard destination != .settings, let slot = DesktopCommand.numberSlot(value),
        let task = numberedSidebarTask(at: slot.index) else { return false }
      return canSelectTask(task)
    case "plan": return destination == .workspace && canStartChat
    case "find-next", "find-previous":
      return destination == .workspace && indexedFindText == findText
        && indexedFindTask == selectedTask?.id && !findMatches.isEmpty
    case "previous-task", "next-task": return filePreviewFocused || browserFocused
      || (!visibleTasks.isEmpty && activeLocalRun == nil && !busy)
    case "back":
      return destination != .workspace || (!navigationBack.isEmpty && activeLocalRun == nil && !busy)
    case "forward":
      return canGoForwardToPluginDetail
        || (destination == .workspace && !navigationForward.isEmpty && activeLocalRun == nil && !busy)
    case "sidebar": return destination != .settings
    case "bottom-panel": return project != nil
    case "new", "new-alternate": return !busy && (project == nil || activeLocalRun == nil)
    case "open": return activeLocalRun == nil && !busy
    case "doctor": return destination == .workspace && canStart
    case "build": return destination == .workspace && canBuild
    case "stop": return selectedActiveRun != nil || activeLocalRun != nil
    case "pet": return petsLoaded
    case "rename", "pin", "unread": return destination == .workspace && selectedTask != nil
    case "archive":
      return destination == .workspace && selectedTask != nil
        && !conversationRuns.contains(where: \.isActive)
    case "files", "tree", "review", "review-open", "terminal":
      return destination == .workspace && project != nil
    default: return true
    }
  }
  func togglePane(_ name: String) {
    if name == "browser" || name == "review" {
      let matchingRightTab = visibleWorkspaceContentTabs(in: .right).contains { tab in
        if name == "browser" { return tab.browserID != nil }
        if case .review = tab { return true }
        return false
      }
      if destination == .workspace, showingInspector, matchingRightTab {
        showingInspector = false
        focusComposer = UUID()
      } else { showPane(name) }
      return
    }
    if destination == .workspace, showingInspector, pane == name {
      showingInspector = false
      focusComposer = UUID()
    } else { showPane(name) }
  }
  func adjacentTaskOrTab(_ offset: Int) {
    if filePreviewFocused { workspace.moveFile(offset) }
    else if !visibleWorkspaceContentTabs.isEmpty { moveWorkspaceTab(offset) }
    else { adjacentTask(offset) }
  }

  func toggleWorkspaceTabVisibility() {
    showingWorkspaceTabs.toggle()
  }

  func toggleWorkspaceTabView() {
    if let tab = activeWorkspaceContentTab {
      moveWorkspaceTab(tab.id, to: .right)
    } else if let tab = activeRightWorkspaceContentTab {
      moveWorkspaceTab(tab.id, to: .left)
    } else { newBrowserTab() }
  }

  func swapWorkspacePanes() {
    guard showingInspector else { return }
    workspaceContentPaneSide.swap()
  }
  func showPane(_ name: String) {
    destination = .workspace
    if name == "browser" {
      pane = name
      if let tab = visibleWorkspaceContentTabs(in: .right).first(where: { $0.browserID != nil }) {
        activateWorkspaceTab(tab.id)
      } else if let tab = visibleWorkspaceContentTabs.first(where: { $0.browserID != nil }) {
        moveWorkspaceTab(tab.id, to: .right)
      } else {
        newBrowserTab(in: .right)
      }
      return
    }
    if name == "review" {
      guard project != nil else { return }
      pane = name
      if let tab = visibleWorkspaceContentTabs(in: .right).first(where: {
        if case .review = $0 { true } else { false }
      }) {
        activateWorkspaceTab(tab.id)
      } else {
        let tab = WorkspaceContentTab.review(owner: currentWorkspaceTabOwner)
        if !workspaceTabs.contains(tab) { workspaceTabs.append(tab) }
        moveWorkspaceTab(tab.id, to: .right)
        Task { await workspace.refreshGit() }
      }
      return
    }
    pane = name
    showingInspector = true
    if name == "files" { Task { await workspace.refreshFiles() } }
  }
  func recordNavigation() {
    let location = TaskLocation(project: currentProjectKey, run: selection)
    if navigationBack.last != location { navigationBack.append(location) }
    navigationForward = []
  }
  func navigate(back: Bool) async {
    if back, destination == .pluginDetail {
      closePluginDetail()
      return
    }
    if !back, canGoForwardToPluginDetail {
      goForwardToPluginDetail()
      return
    }
    if back, destination == .settings {
      closeSettings()
      return
    }
    if back, destination == .projects {
      returnToWorkspace()
      return
    }
    if back, destination == .plugins {
      returnToWorkspace()
      return
    }
    if back, destination == .automations {
      returnToWorkspace()
      return
    }
    guard destination == .workspace, activeLocalRun == nil, !busy else { return }
    let location = back ? navigationBack.popLast() : navigationForward.popLast()
    guard let location else { return }
    let current = TaskLocation(project: currentProjectKey, run: selection)
    if back { navigationForward.append(current) } else { navigationBack.append(current) }
    guard await openTaskScope(location.project) else { return }
    selection = location.run
    rememberProjectSelection()
    saveLibrary()
    await loadDetails()
  }
  func numberedSidebarTask(at number: Int) -> WorkspaceTask? {
    guard (1...9).contains(number) else { return nil }
    let tasks = library.visibleSidebarTasks
    return tasks.indices.contains(number - 1) ? tasks[number - 1] : nil
  }

  func adjacentTask(_ offset: Int) {
    let tasks = visibleTasks
    guard !tasks.isEmpty else { return }
    let index = tasks.firstIndex(where: { $0.id == selectedTask?.id }) ?? 0
    selectTask(tasks[(index + offset + tasks.count) % tasks.count])
  }
  func restorePrompt() {
    guard draft.isEmpty, let taskID = selectedTask?.id,
      let prompt = previousPrompt(taskID: taskID)
    else { return }
    draft = prompt
  }
  func previousPrompt(taskID: String) -> String? {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return nil }
    return task.runIDs.reversed().compactMap { id -> String? in
      guard let prompt = library.notes[id],
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return prompt
    }.first
  }
  func toggleProjectPin(_ path: String) {
    library.moveSidebarItem(
      .project(path),
      to: library.pinnedProjects.contains(path) ? SidebarLayout.projects : SidebarLayout.pinned)
    saveLibrary()
  }
  func archiveProject(_ path: String) {
    for task in library.tasks where task.project == path { updateTask(task.id, archive: true) }
  }
  func moveFindMatch(_ offset: Int) {
    let count = findMatches.count
    guard count > 0, indexedFindText == findText, indexedFindTask == selectedTask?.id else {
      return
    }
    showingFind = true
    findIndex = ((findIndex + offset) % count + count) % count
    findRequest = UUID()
  }
}
