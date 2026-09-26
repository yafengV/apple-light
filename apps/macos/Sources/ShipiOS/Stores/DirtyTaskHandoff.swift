import Foundation

extension WorkspaceStore {
  func beginDirtyHandoff(taskID: String, direction: HandoffDirection,
    source: URL, target: URL) async throws {
    guard library.managedWorktrees.contains(where: {
      $0.taskID == taskID && $0.pendingHandoff == nil
    }) else {
      throw AgentFailure(message: "上一次任务移交仍待完成。")
    }
    let snapshot = try await HandoffGitState.capture(taskID: taskID,
      source: source, target: target, dataRoot: dataRoot)
    do {
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else {
        throw AgentFailure(message: "工作树任务记录已丢失。")
      }
      candidate.managedWorktrees[index].pendingHandoff = PendingHandoff(
        direction: direction, snapshot: snapshot, phase: .applying)
      try commitLibrary(candidate)
    } catch {
      try? await HandoffGitState.discardUnapplied(snapshot, dataRoot: dataRoot)
      throw error
    }
    try await finishPendingHandoff(taskID: taskID, openMovedTask: true)
  }

  /// Resume after any persisted phase. No source cleanup starts until the target is verified.
  func finishPendingHandoff(taskID: String, openMovedTask: Bool) async throws {
    for _ in 0..<4 {
      guard let pending = library.managedWorktrees.first(where: { $0.taskID == taskID })?.pendingHandoff else {
        return
      }
      let snapshot = pending.snapshot
      switch pending.phase {
      case .applying:
        try await HandoffGitState.apply(snapshot, dataRoot: dataRoot)
        try updateHandoffPhase(taskID: taskID, to: .clearing)
      case .clearing:
        try await HandoffGitState.clearSource(snapshot, dataRoot: dataRoot)
        try updateHandoffPhase(taskID: taskID, to: .finalizing)
      case .finalizing:
        // Repeat the idempotent validation before making the destination the task's home.
        try await HandoffGitState.clearSource(snapshot, dataRoot: dataRoot)
        var candidate = library
        guard let taskIndex = candidate.tasks.firstIndex(where: {
          $0.id == taskID && $0.project == snapshot.sourcePath
        }), let recordIndex = candidate.managedWorktrees.firstIndex(where: {
          $0.taskID == taskID && $0.pendingHandoff?.phase == .finalizing
        }) else {
          throw AgentFailure(message: "任务或移交记录已改变，未移动会话。")
        }
        let task = candidate.tasks[taskIndex]
        candidate.tasks[taskIndex].project = snapshot.targetPath
        candidate.tasks[taskIndex].updatedAt = Date()
        candidate.projectSelections[snapshot.targetPath] = task.selectionID
        if candidate.projectSelections[snapshot.sourcePath] == task.selectionID {
          candidate.projectSelections[snapshot.sourcePath] = nil
        }
        if let profile = candidate.profiles[snapshot.sourcePath] {
          candidate.profiles[snapshot.targetPath] = profile
        }
        candidate.managedWorktrees[recordIndex].pendingHandoff?.phase = .releasing
        try commitLibrary(candidate)
      case .releasing:
        try await HandoffGitState.release(snapshot, dataRoot: dataRoot)
        var candidate = library
        guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else {
          throw AgentFailure(message: "工作树任务记录已丢失。")
        }
        candidate.managedWorktrees[index].pendingHandoff = nil
        try commitLibrary(candidate)
        if openMovedTask && currentProjectKey == snapshot.sourcePath {
          selection = nil
          guard await openTaskScope(snapshot.targetPath) else {
            throw AgentFailure(message: "任务已移交，但无法打开目标目录。请从侧栏重新选择任务。")
          }
          if let moved = library.tasks.first(where: { $0.id == taskID }) {
            applyTaskSelection(moved)
          }
        }
        return
      }
    }
    throw AgentFailure(message: "任务移交尚未完成，请重试。")
  }

  func schedulePendingHandoffRecovery() {
    let pendingIDs = library.managedWorktrees.compactMap { record in
      record.pendingHandoff == nil ? nil : record.taskID
    }
    guard !pendingIDs.isEmpty, pendingHandoffRecoveryTask == nil else { return }
    recoveringHandoffTaskIDs.formUnion(pendingIDs)
    pendingHandoffRecoveryTask = Task { @MainActor in
      await restorePendingHandoffs(pendingIDs)
    }
  }

  private func restorePendingHandoffs(_ pendingIDs: [String]) async {
    for taskID in pendingIDs {
      let noticeID = "handoff-resume-" + taskID
      notices.show(id: noticeID, title: "正在继续任务移交…", level: .pending)
      do {
        try await finishPendingHandoff(taskID: taskID, openMovedTask: false)
        notices.show(id: noticeID, title: "任务移交已恢复", level: .success,
          taskID: taskID)
      } catch {
        notices.show(id: noticeID,
          title: "任务移交待恢复：\(error.localizedDescription)", level: .error)
      }
      recoveringHandoffTaskIDs.remove(taskID)
    }
  }

  private func updateHandoffPhase(taskID: String, to phase: HandoffPhase) throws {
    var candidate = library
    guard let index = candidate.managedWorktrees.firstIndex(where: {
      $0.taskID == taskID && $0.pendingHandoff != nil
    }) else {
      throw AgentFailure(message: "任务移交记录已丢失。")
    }
    candidate.managedWorktrees[index].pendingHandoff?.phase = phase
    try commitLibrary(candidate)
  }
}
