import AppKit

extension WorkspaceStore {
  var effectiveWorkspaceContentLayoutMode: WorkspaceContentLayoutMode {
    workspaceContentLayoutMode ?? (visibleWorkspaceContentTabs(in: .left).contains {
      $0.id == activeWorkspaceTabID
    } ? .full : .split)
  }
  var claimsAdjacentContentTabs: Bool {
    filePreviewFocused || focusedWorkspaceContentTab != nil || activeWorkspaceContentTab != nil
      || (effectiveWorkspaceContentLayoutMode == .full && visibleWorkspaceContentTabs.contains {
        [.left, .right].contains(workspaceTabPlacement($0.id))
      }) || (browserFocused && workspace.browser.tabs.count > 1)
  }
  var taskNavigationShortcutContext: RecentTaskShortcutContext? {
    guard destination == .workspace, !libraryRecoveryBlocksInteraction,
      shortcutCaptureCount == 0, presentedOverlay == nil, !hasSettingsConfirmation,
      !showingModelPicker, !showingBranchPicker, !busy, activeLocalRun == nil, !shuttingDown else { return nil }
    return RecentTaskShortcutContext(currentID: selectedTask?.id, recentIDs: library.recentTaskIDs,
      isAvailable: { [weak self] id in
        guard let self, let task = self.library.tasks.first(where: { $0.id == id }),
          !task.archived, !task.isTransient else { return false }
        return self.canSelectTask(task)
      }, title: { [weak self] id in self?.library.tasks.first(where: { $0.id == id })?.title ?? "" },
      select: { [weak self] id in
        guard let self, let task = self.library.tasks.first(where: { $0.id == id }) else { return }
        self.selectTask(task)
      }, claimsTabs: { [weak self] in
        guard let self else { return false }
        return self.claimsAdjacentContentTabs
      }, selectTab: { [weak self] direction in self?.adjacentContentTab(direction) ?? false })
  }

  @discardableResult func adjacentContentTab(_ direction: Int) -> Bool {
    if filePreviewFocused {
      guard workspace.openFiles.count > 1 else { return false }
      workspace.moveFile(direction); return true
    }
    if let focused = focusedWorkspaceContentTab, workspaceTabStripPlacement(focused.id) == .bottom {
      let tabs = visibleWorkspaceContentTabs(in: .bottom)
      guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == focused.id }) else { return false }
      activateWorkspaceTab(tabs[(index + direction + tabs.count) % tabs.count].id); return true
    }
    let full = effectiveWorkspaceContentLayoutMode == .full
    guard full || focusedWorkspaceContentTab != nil || browserFocused else { return false }
    let content = workspacePrimaryContentTabs
    let ids: [String?] = (full ? [nil] : []) + content.map { Optional($0.id) }
    guard ids.count > 1 else { return false }
    let current = focusedWorkspaceContentTab?.id ?? (full ? activeWorkspaceTabID : activeRightWorkspaceTabID)
    let index = ids.firstIndex { $0 == current } ?? 0
    activateWorkspaceTab(ids[(index + direction + ids.count) % ids.count]); return true
  }
  @discardableResult func moveLegacyBrowserTab(_ direction: Int) -> Bool {
    let owned = Set(visibleWorkspaceContentTabs.compactMap(\.browserID))
    let ids = workspace.browser.tabs.map(\.id).filter { owned.contains($0) }
    guard ids.count > 1 else { return false }
    let index = ids.firstIndex { $0 == workspace.browser.selection } ?? 0
    workspace.browser.select(ids[(index + direction + ids.count) % ids.count]); return true
  }

}
