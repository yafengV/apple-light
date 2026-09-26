import Foundation

extension WorkspaceStore {
  func canHandOffToWorktree(_ task: WorkspaceTask) -> Bool {
    libraryLoaded && !busy && !managedTaskPreparing && activeLocalRun == nil
      && activeRun(taskID: task.id) == nil && !task.archived && !task.isPopoutDraft
      && !task.project.isEmpty && library.projects.contains(task.project)
      && !library.isPermanentWorktree(task.project)
      && !library.managedWorktrees.contains { $0.path == task.project }
  }

  /// Keep the task and its private Codex rollout, then reopen it from a detached checkout.
  /// Dirty local checkouts are rejected until their Git state can be moved without touching
  /// unrelated work in the shared local project.
  @discardableResult func handOffTaskToWorktree(_ taskID: String) async -> Bool {
    guard let task = library.tasks.first(where: { $0.id == taskID }),
      canHandOffToWorktree(task) else {
      worktreeError = "请等待任务完成，并从本地 Git 项目迁移现有任务。"
      error = worktreeError
      return false
    }
    managedTaskPreparing = true
    worktreeError = nil
    defer { managedTaskPreparing = false; scheduleManagedLimitCleanup() }
    let source = URL(fileURLWithPath: task.project)
    var capturedFiles = false
    do {
      let snapshot = try await GitBranchService.snapshot(at: source)
      guard snapshot.canChange else {
        throw AgentFailure(message: "请打开 Git 仓库根目录后迁移任务。")
      }
      guard snapshot.changedFiles == 0 else {
        throw AgentFailure(message: "本地检出有未提交修改；请先提交或整理修改，再迁移任务。")
      }
      let existing = library.managedWorktrees.first { $0.taskID == taskID }
      guard existing == nil || existing?.source == snapshot.root.path else {
        throw AgentFailure(message: "此任务已关联其他项目的工作树。")
      }
      let copiedFiles: [ManagedSourceFile]
      if existing == nil {
        let paths = try await ManagedSourceFiles.discover(at: source, excluding: dataRoot)
        copiedFiles = try ManagedSourceFiles.capture(paths, from: source,
          dataRoot: dataRoot, taskID: taskID)
        capturedFiles = !copiedFiles.isEmpty
      } else {
        copiedFiles = []
      }
      guard let record = await createManagedWorktree(snapshot: snapshot, branch: nil,
        taskID: taskID, sourceCopiedFiles: copiedFiles) else {
        throw AgentFailure(message: worktreeError ?? "无法创建任务工作树。")
      }
      if (record.sourceStashCommit != nil || !(record.sourceCopiedFiles ?? []).isEmpty),
        record.sourceChangesApplied != true {
        try await applyManagedSourceChanges(record)
      }
      guard record.archivedPruned != true,
        FileManager.default.fileExists(atPath: record.path) else {
        throw AgentFailure(message: "任务工作树尚未恢复，请先在工作树设置中恢复。")
      }
      let target = URL(fileURLWithPath: record.path)
      let targetSnapshot = try await GitBranchService.snapshot(at: target)
      let sourceAfterCreation = try await GitBranchService.snapshot(at: source)
      guard targetSnapshot.currentCommit == snapshot.currentCommit,
        targetSnapshot.changedFiles == 0,
        sourceAfterCreation.currentCommit == snapshot.currentCommit,
        sourceAfterCreation.changedFiles == 0 else {
        throw AgentFailure(message: "迁移期间 Git 状态发生变化，任务仍留在本地；请检查两个检出后重试。")
      }
      var candidate = library
      guard let index = candidate.tasks.firstIndex(where: {
        $0.id == taskID && $0.project == snapshot.root.path
      }) else {
        throw AgentFailure(message: "任务位置已改变，未迁移。")
      }
      candidate.tasks[index].project = record.path
      candidate.tasks[index].updatedAt = Date()
      candidate.projectSelections[record.path] = task.selectionID
      if candidate.projectSelections[snapshot.root.path] == task.selectionID {
        candidate.projectSelections[snapshot.root.path] = nil
      }
      if let profile = candidate.profiles[snapshot.root.path] {
        candidate.profiles[record.path] = profile
      }
      try commitLibrary(candidate)
      if currentProjectKey == snapshot.root.path {
        selection = nil
        guard await openTaskScope(record.path) else {
          throw AgentFailure(message: "任务已迁移，但无法打开工作树。请从侧栏重新选择任务。")
        }
        if let moved = library.tasks.first(where: { $0.id == taskID }) {
          applyTaskSelection(moved)
        }
      }
      error = nil
      worktreeError = nil
      return true
    } catch {
      if capturedFiles && !library.managedWorktrees.contains(where: { $0.taskID == taskID }) {
        ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID)
      }
      worktreeError = error.localizedDescription
      self.error = error.localizedDescription
      return false
    }
  }
}
