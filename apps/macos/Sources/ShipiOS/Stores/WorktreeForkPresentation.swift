import Foundation

extension WorkspaceStore {
  var showingWorktreeForkPreparation: Bool {
    destination == .workspace && worktreeForkPresentation.preparation != nil
  }

  func setWorktreeForkPhase(_ message: String) {
    managedTaskPreparationMessage = message
    activeWorktreeForkPreparation?.phase = message
  }

  /// Waiters and the page's Cancel button cancel the same worker, not an unrelated view task.
  func runWorktreeForkPreparation(_ preparation: WorktreeForkPreparation,
    presentation: WorktreeForkPresentation?, operation: @escaping () async -> WorkspaceTask?
  ) async -> WorkspaceTask? {
    managedTaskPreparing = true
    activeWorktreeForkPreparation = preparation
    presentation?.present(preparation)
    let ongoing = library.chatRuns.filter { modelTask(runID: $0.id) != nil }.map(\.id)
    let worker = Task { await operation() }
    preparation.operation = worker
    let result = await withTaskCancellationHandler {
      await worker.value
    } onCancel: { worker.cancel() }
    defer {
      preparation.finish(result)
      scheduleManagedLimitCleanup()
      Task { await resumeChatsAfterWorktreePreparation(ongoing) }
    }
    preparation.operation = nil
    activeWorktreeForkPreparation = nil
    managedTaskPreparing = false
    managedTaskPreparationMessage = "正在创建工作树…"
    if let result {
      preparation.state = .ready
      guard !Task.isCancelled, !shuttingDown else { return result }
      var owners = [worktreeForkPresentation] + taskWindowResources.allObjects.map(\.worktreeForkPresentation)
      if let presentation, !owners.contains(where: { $0 === presentation }) { owners.append(presentation) }
      var shown = false
      for owner in owners where owner.owns(preparation) {
        shown = true
        await openPreparedWorktreeFork(in: owner)
      }
      if !shown, presentation != nil {
        preparation.notices.show(id: "worktree-fork-ready-\(result.id)", title: "工作树聊天分支已准备完成",
          level: .success, taskID: result.id)
      }
    } else if worker.isCancelled || Task.isCancelled {
      preparation.state = .cancelled
    }
    return result
  }

  func openPreparedWorktreeFork(in presentation: WorktreeForkPresentation) async {
    guard let preparation = presentation.preparation, preparation.state == .ready,
      let task = library.tasks.first(where: { $0.id == preparation.taskID && !$0.archived }),
      !shuttingDown else { return }
    if presentation === worktreeForkPresentation {
      await revealPreparedWorktreeFork(task, preparation: preparation)
    } else {
      await presentation.onReady?(task)
      if presentation.owns(preparation) { presentation.dismiss() }
    }
  }

  func retryWorktreeFork(in presentation: WorktreeForkPresentation) async {
    guard let preparation = presentation.preparation, preparation.state != .preparing,
      !managedTaskPreparing, !shuttingDown else { return }
    if let id = preparation.taskID, library.managedWorktrees.contains(where: {
      $0.taskID == id && $0.pendingForkSourceTaskID != nil
    }) {
      _ = await resumeWorktreeFork(id, openTask: false, presentation: presentation, noticeBoard: preparation.notices)
    } else {
      _ = await forkTaskToNewWorktree(preparation.sourceTaskID, openTask: false,
        presentation: presentation, noticeBoard: preparation.notices)
    }
  }

  private func revealPreparedWorktreeFork(_ task: WorkspaceTask, preparation: WorktreeForkPreparation) async {
    // Opening a scope has awaits too. A page change must invalidate both preparation and opening.
    let stillValid = { !self.shuttingDown && !Task.isCancelled && self.destination == .workspace
      && self.worktreeForkPresentation.owns(preparation) }
    guard stillValid(), await openTaskScope(task.project,
      preservingWorktreePreparation: preparation, stillValid: stillValid), stillValid(),
      let current = library.tasks.first(where: { $0.id == task.id && !$0.archived }) else { return }
    recordNavigation()
    worktreeForkPresentation.dismiss()
    applyTaskSelection(current)
    action = .chat
  }
}
