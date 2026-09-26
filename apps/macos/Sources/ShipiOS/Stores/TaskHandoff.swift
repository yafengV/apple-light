import Foundation

extension WorkspaceStore {
  func canHandOffToWorktree(_ task: WorkspaceTask) -> Bool {
    libraryLoaded && !busy && !managedTaskPreparing && activeLocalRun == nil
      && activeRun(taskID: task.id) == nil && !task.archived && !task.isPopoutDraft
      && !task.project.isEmpty && library.projects.contains(task.project)
      && !library.isPermanentWorktree(task.project)
      && !library.managedWorktrees.contains { $0.path == task.project }
  }

  func canHandOffToLocal(_ task: WorkspaceTask) -> Bool {
    guard libraryLoaded, !busy, !managedTaskPreparing, activeLocalRun == nil,
      activeRun(taskID: task.id) == nil, !task.archived, !task.isPopoutDraft,
      let record = library.managedWorktrees.first(where: { $0.taskID == task.id }) else {
      return false
    }
    return record.ready && task.project == record.path
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
      if let retained = library.managedWorktrees.first(where: { $0.taskID == taskID }),
        retained.archivedPruned == true || !FileManager.default.fileExists(atPath: retained.path) {
        guard await restoreManagedArchiveIfNeeded(taskID) else {
          throw AgentFailure(message: archivedTaskDeletionError ?? "无法恢复关联工作树。")
        }
      }
      let existing = library.managedWorktrees.first { $0.taskID == taskID }
      guard existing == nil || existing?.source == snapshot.root.path else {
        throw AgentFailure(message: "此任务已关联其他项目的工作树。")
      }
      if let branch = existing?.handoffBranch,
        snapshot.currentReference != "refs/heads/" + branch {
        throw AgentFailure(message: "请先把本地检出切回任务分支 \(branch)，再移交到工作树。")
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
      if existing != nil {
        guard targetSnapshot.currentReference == nil, targetSnapshot.changedFiles == 0,
          let targetHead = targetSnapshot.currentCommit,
          let sourceHead = snapshot.currentCommit else {
          throw AgentFailure(message: "关联工作树有未提交修改或已切换分支，未覆盖该目录。")
        }
        let localFiles = try await ManagedSourceFiles.discover(at: source, excluding: dataRoot)
        guard (try? ManagedSourceFiles.matchExisting(localFiles, between: source, and: target)) == true else {
          throw AgentFailure(message: "两个检出的本地配置文件不同，未覆盖关联工作树。")
        }
        if targetHead != sourceHead {
          guard try await handoffIsAncestor(targetHead, of: sourceHead, at: source) else {
            throw AgentFailure(message: "关联工作树与本地提交已分叉，未重写 Git 历史。")
          }
          _ = try await GitReviewService.checked(
            ["switch", "--detach", "--no-overwrite-ignore", sourceHead], at: target)
        }
      }
      let targetAfterCreation = try await GitBranchService.snapshot(at: target)
      let sourceAfterCreation = try await GitBranchService.snapshot(at: source)
      guard targetAfterCreation.currentCommit == snapshot.currentCommit,
        targetAfterCreation.changedFiles == 0,
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

  /// Check out the task's committed work on a reserved local branch. The worktree stays
  /// associated with the task, so another handoff returns to the same detached checkout.
  @discardableResult func handOffTaskToLocal(_ taskID: String) async -> Bool {
    guard let task = library.tasks.first(where: { $0.id == taskID }),
      canHandOffToLocal(task),
      let original = library.managedWorktrees.first(where: { $0.taskID == taskID }) else {
      worktreeError = "请等待任务完成，并从托管工作树移交现有任务。"
      error = worktreeError
      return false
    }
    managedTaskPreparing = true
    worktreeError = nil
    defer { managedTaskPreparing = false; scheduleManagedLimitCleanup() }
    do {
      if original.archivedPruned == true || !FileManager.default.fileExists(atPath: original.path) {
        guard await restoreManagedArchiveIfNeeded(taskID) else {
          throw AgentFailure(message: archivedTaskDeletionError ?? "无法恢复关联工作树。")
        }
      }
      guard let record = library.managedWorktrees.first(where: { $0.taskID == taskID }) else {
        throw AgentFailure(message: "工作树任务记录已丢失。")
      }
      try await WorktreeService.validateRetainedManaged(record)
      let source = URL(fileURLWithPath: record.source)
      let target = URL(fileURLWithPath: record.path)
      let local = try await GitBranchService.snapshot(at: source)
      let worktree = try await GitBranchService.snapshot(at: target)
      guard local.canChange, worktree.canChange,
        local.changedFiles == 0, worktree.changedFiles == 0,
        worktree.currentReference == nil, let head = worktree.currentCommit else {
        throw AgentFailure(message: "两边检出都需要没有未提交修改，且任务工作树保持 detached HEAD。")
      }
      let included = try await ManagedSourceFiles.discover(at: target, excluding: dataRoot)
      guard (try? ManagedSourceFiles.matchExisting(included, between: target, and: source)) == true else {
        throw AgentFailure(message: "两个检出的本地配置文件不同，未覆盖本地目录。")
      }
      let branch = record.handoffBranch
        ?? (library.gitPreferences.branchPrefix + "shipios-" + taskID.lowercased())
      let branchRef = "refs/heads/" + branch
      let branchTip = try await LocalWorkspaceService.git(
        ["rev-parse", "--verify", branchRef + "^{commit}"], at: source)
      if record.handoffBranch == nil {
        try await GitCommitSelection.validateBranch(branch, at: source)
      } else {
        let checked = try await LocalWorkspaceService.git(
          ["check-ref-format", "--branch", branch], at: source)
        guard checked.status == 0 else {
          throw AgentFailure(message: "已保存的移交分支名称无效，未修改本地目录。")
        }
      }
      let tip = branchTip.status == 0
        ? branchTip.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
      let expectedHead: String
      if let tip, tip != head {
        if try await handoffIsAncestor(tip, of: head, at: source) {
          expectedHead = head
        } else if try await handoffIsAncestor(head, of: tip, at: source) {
          expectedHead = tip
        } else {
          throw AgentFailure(message: "本地任务分支与工作树提交已分叉，未重写 Git 历史。")
        }
      } else {
        expectedHead = head
      }
      if record.handoffBranch == nil {
        var reserved = library
        guard let index = reserved.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else {
          throw AgentFailure(message: "工作树任务记录已丢失。")
        }
        reserved.managedWorktrees[index].handoffBranch = branch
        try commitLibrary(reserved)
      }
      let localBeforeSwitch = try await GitBranchService.snapshot(at: source)
      let targetBeforeSwitch = try await GitBranchService.snapshot(at: target)
      guard localBeforeSwitch.currentReference == local.currentReference,
        localBeforeSwitch.currentCommit == local.currentCommit,
        localBeforeSwitch.changedFiles == 0,
        targetBeforeSwitch.currentReference == nil,
        targetBeforeSwitch.currentCommit == head,
        targetBeforeSwitch.changedFiles == 0 else {
        throw AgentFailure(message: "移交期间 Git 状态发生变化，未修改本地分支。")
      }
      if tip == nil {
        _ = try await GitReviewService.checked(
          ["switch", "--no-overwrite-ignore", "--no-track", "-c", branch, head], at: source)
      } else {
        _ = try await GitReviewService.checked(
          ["switch", "--no-overwrite-ignore", "--no-guess", branch], at: source)
        if tip != expectedHead {
          _ = try await GitReviewService.checked(["merge", "--ff-only", head], at: source)
        }
      }
      let localAfterSwitch = try await GitBranchService.snapshot(at: source)
      guard localAfterSwitch.currentReference == branchRef,
        localAfterSwitch.currentCommit == expectedHead,
        localAfterSwitch.changedFiles == 0 else {
        throw AgentFailure(message: "本地分支切换后校验失败，请检查 Git 状态。")
      }
      var candidate = library
      guard let index = candidate.tasks.firstIndex(where: {
        $0.id == taskID && $0.project == record.path
      }) else {
        throw AgentFailure(message: "任务位置已改变，未迁移。")
      }
      candidate.tasks[index].project = record.source
      candidate.tasks[index].updatedAt = Date()
      candidate.projectSelections[record.source] = task.selectionID
      if candidate.projectSelections[record.path] == task.selectionID {
        candidate.projectSelections[record.path] = nil
      }
      try commitLibrary(candidate)
      if currentProjectKey == record.path {
        selection = nil
        guard await openTaskScope(record.source) else {
          throw AgentFailure(message: "任务已移交到本地，但无法打开该目录。请从侧栏重试。")
        }
        if let moved = library.tasks.first(where: { $0.id == taskID }) {
          applyTaskSelection(moved)
        }
      }
      error = nil
      worktreeError = nil
      return true
    } catch {
      worktreeError = error.localizedDescription
      self.error = error.localizedDescription
      return false
    }
  }

  private func handoffIsAncestor(_ older: String, of newer: String, at root: URL) async throws -> Bool {
    let check = try await LocalWorkspaceService.git(
      ["merge-base", "--is-ancestor", older, newer], at: root)
    if check.status == 0 { return true }
    if check.status == 1 { return false }
    throw AgentFailure(message: "无法比较两个检出的提交：\(check.text)")
  }
}
