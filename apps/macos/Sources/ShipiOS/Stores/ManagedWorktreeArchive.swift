import Foundation

extension WorkspaceStore {
  func runManagedWorktreeCleanup(_ record: ManagedWorktree) async throws {
    guard let current = library.managedWorktrees.first(where: { $0.taskID == record.taskID }),
      current.ready, FileManager.default.fileExists(atPath: current.path) else {
      throw AgentFailure(message: "托管工作树已改变，无法运行清理脚本。")
    }
    guard current.cleanupCompleted != true else { return }
    let script = current.environment?.macOSCleanupScript
      ?? library.profiles[current.source]?.macOSCleanupScript ?? ""
    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    try await LocalEnvironmentScriptService.run(script, phase: .cleanup,
      source: URL(fileURLWithPath: current.source), worktree: URL(fileURLWithPath: current.path))
    var candidate = library
    guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == current.taskID }) else {
      throw AgentFailure(message: "清理脚本已执行，但工作树记录已丢失；请检查项目。")
    }
    candidate.managedWorktrees[index].cleanupCompleted = true
    try commitLibrary(candidate)
  }

  func scheduleManagedArchiveCleanup(_ taskID: String) {
    let previous = managedArchiveCleanupTask
    managedArchiveCleanupTask = Task { @MainActor in
      await previous?.value
      await pruneManagedWorktreeIfEligible(taskID)
    }
  }

  func pruneManagedWorktreeIfEligible(_ requestedTaskID: String, dueToLimit: Bool = false) async {
    await Task.yield()
    // Archiving the selected task starts a source-project transition. Wait for that
    // transition, then recheck every user; do not silently discard this cleanup.
    while busy && preparingProjectScope && !shuttingDown {
      do { try await Task.sleep(for: .milliseconds(25)) }
      catch { return }
    }
    guard !shuttingDown, let record = library.managedWorktree(forTaskID: requestedTaskID),
      !busy, !managedTaskPreparing, record.pendingForkSourceTaskID == nil,
      record.pendingHandoff == nil else { return }
    let members = library.managedTasks(for: record)
    guard !members.isEmpty, members.allSatisfy({ $0.archived || dueToLimit }) else { return }
    if members.contains(where: \.pinned) {
      notices.show(id: "managed-archive-" + record.taskID,
        title: "置顶任务的工作树已保留", level: .info)
      return
    }
    guard managedCheckoutCanPrune(record, dueToLimit: dueToLimit) else { return }
    // All snapshot paths and Git refs retain the original physical checkout identity.
    let taskID = record.taskID
    let noticeID = "managed-archive-" + taskID
    if managedCheckoutHasOpenWindow(record) {
      try? await Task.sleep(for: .milliseconds(300))
    }
    if managedCheckoutHasOpenWindow(record) {
      notices.show(id: noticeID, title: "任务窗口仍在使用工作树，已保留目录", level: .info)
      return
    }
    if project?.path == record.path {
      if dueToLimit { return }
      await open(URL(fileURLWithPath: record.source))
      guard project?.path != record.path else {
        notices.show(id: noticeID, title: "项目仍在使用工作树，已保留目录", level: .info)
        return
      }
    }
    if record.archivedHead != nil, FileManager.default.fileExists(atPath: record.path) {
      notices.show(id: noticeID, title: "上次归档快照仍待处理，已保留目录；请恢复任务后重试", level: .info)
      return
    }
    guard !busy, !managedTaskPreparing,
      let latest = library.managedWorktree(forTaskID: requestedTaskID), latest == record,
      managedCheckoutCanPrune(record, dueToLimit: dueToLimit),
      !managedCheckoutHasOpenWindow(record) else { return }
    let ongoingChats = library.chatRuns.filter { modelTask(runID: $0.id) != nil }.map(\.id)
    busy = true
    managedTaskPreparing = true
    managedTaskPreparationMessage = "正在清理工作树…"
    defer {
      busy = false
      managedTaskPreparing = false
      managedTaskPreparationMessage = "正在创建工作树…"
      Task { await resumeChatsAfterWorktreePreparation(ongoingChats) }
    }
    var protectedHead: String?
    var protectedStash: String?
    var snapshotCaptured = false
    var stateCommitted = false
    do {
      if !FileManager.default.fileExists(atPath: record.path) {
        guard record.archivedHead != nil else {
          throw AgentFailure(message: "工作树目录已消失，且没有可恢复的提交。")
        }
        var candidate = library
        guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else { return }
        candidate.managedWorktrees[index].archivedPruned = true
        try commitLibrary(candidate)
        return
      }
      let checkout = URL(fileURLWithPath: record.path)
      let source = URL(fileURLWithPath: record.source)
      let common = GitBranchService.canonicalRoot(
        URL(fileURLWithPath: record.checkout.commonDirectory))
      guard GitBranchService.canonicalRoot(source).path == record.source,
        GitBranchService.canonicalRoot(checkout).path == record.path,
        try await WorktreeService.commonDirectory(at: source) == common,
        try await WorktreeService.commonDirectory(at: checkout) == common else {
        throw AgentFailure(message: "工作树或来源仓库已改变，未运行清理脚本。")
      }
      try await runManagedWorktreeCleanup(record)
      guard managedCheckoutCanPrune(record, dueToLimit: dueToLimit),
        !managedCheckoutHasOpenWindow(record), project?.path != record.path else { return }
      let status = try await GitReviewService.checked(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: checkout)
      let ignored = try await GitReviewService.checked(
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: checkout)
      let hasUncommittedFiles = !status.isEmpty || !ignored.isEmpty
      let snapshot = try await GitBranchService.snapshot(at: checkout)
      guard let head = snapshot.currentCommit else {
        throw AgentFailure(message: "工作树没有可恢复的提交，已保留目录。")
      }
      var copiedFiles: [ManagedSourceFile] = []
      var stashCommit: String?
      if hasUncommittedFiles {
        let paths = try await ManagedSourceFiles.discoverAll(at: checkout,
          excluding: dataRoot)
        copiedFiles = try ManagedSourceFiles.capture(paths, from: checkout,
          dataRoot: dataRoot, taskID: taskID)
        snapshotCaptured = !copiedFiles.isEmpty
        let captured = try await GitReviewService.stashSnapshot(
          named: "shipios-archive-\(taskID)", at: checkout)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !captured.isEmpty {
          guard captured.range(of: "^[0-9a-f]{40,64}$",
            options: .regularExpression) != nil else {
            throw AgentFailure(message: "无法保存工作树的已跟踪修改，已保留目录。")
          }
          _ = try await GitReviewService.checked(
            ["update-ref", "refs/shipios/managed-archive-dirty/\(taskID)", captured],
            at: URL(fileURLWithPath: record.source))
          stashCommit = captured
          protectedStash = captured
        }
        guard stashCommit != nil || !copiedFiles.isEmpty else {
          throw AgentFailure(message: "无法保存工作树的未提交内容，已保留目录。")
        }
      }
      let reference = "refs/shipios/managed-archive/" + taskID
      _ = try await GitReviewService.checked(["update-ref", reference, head],
        at: URL(fileURLWithPath: record.source))
      protectedHead = head
      guard managedCheckoutCanPrune(record, dueToLimit: dueToLimit),
        !managedCheckoutHasOpenWindow(record), project?.path != record.path else {
        throw AgentFailure(message: "任务重新开始使用工作树，已保留目录。")
      }
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else { return }
      candidate.managedWorktrees[index].archivedHead = head
      candidate.managedWorktrees[index].archivedStashCommit = stashCommit
      candidate.managedWorktrees[index].archivedCopiedFiles = copiedFiles.isEmpty ? nil : copiedFiles
      candidate.managedWorktrees[index].checkout = archivedCheckout(record.checkout, head: head)
      try commitLibrary(candidate)
      stateCommitted = true
      if stashCommit == nil, let previous = record.archivedStashCommit {
        _ = try? await GitReviewService.checked(
          ["update-ref", "-d", "refs/shipios/managed-archive-dirty/\(taskID)", previous],
          at: URL(fileURLWithPath: record.source))
      }
      if copiedFiles.isEmpty { ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID) }
      let removed = hasUncommittedFiles
        ? try await WorktreeService.removeSnapshottedManaged(
          candidate.managedWorktrees[index], dataRoot: dataRoot)
        : try await WorktreeService.removeCleanManaged(candidate.managedWorktrees[index])
      guard removed else {
        notices.show(id: noticeID, title: "工作树在快照后发生修改，已保留目录", level: .info)
        return
      }
      var completed = library
      guard let completedIndex = completed.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else { return }
      completed.managedWorktrees[completedIndex].archivedPruned = true
      try commitLibrary(completed)
      notices.show(id: noticeID, title: "已保存提交并清理工作树，恢复任务时可重建", level: .info)
    } catch {
      if !stateCommitted {
        if snapshotCaptured { ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID) }
        if let protectedStash {
          _ = try? await GitReviewService.checked(
            ["update-ref", "-d", "refs/shipios/managed-archive-dirty/\(taskID)", protectedStash],
            at: URL(fileURLWithPath: record.source))
        }
        if let protectedHead {
          _ = try? await GitReviewService.checked(
            ["update-ref", "-d", "refs/shipios/managed-archive/\(taskID)", protectedHead],
            at: URL(fileURLWithPath: record.source))
        }
      }
      notices.show(id: noticeID, title: "工作树已保留：\(error.localizedDescription)", level: .error)
    }
  }

  private func managedCheckoutCanPrune(_ record: ManagedWorktree, dueToLimit: Bool) -> Bool {
    let members = library.managedTasks(for: record)
    guard !members.isEmpty else { return false }
    return members.allSatisfy {
      ($0.archived || dueToLimit) && !$0.pinned && activeRun(taskID: $0.id) == nil
    }
  }

  private func managedCheckoutHasOpenWindow(_ record: ManagedWorktree) -> Bool {
    taskWindowResources.allObjects.contains { resources in
      resources.window != nil && library.managedTasks(for: record).contains {
        resources.tasks[$0.id] != nil
      }
    }
  }

  /// Recreate a checkout pruned by archiving or the configured worktree limit.
  func restoreManagedArchiveIfNeeded(_ requestedTaskID: String) async -> Bool {
    await managedArchiveCleanupTask?.value
    await managedLimitCleanupTask?.value
    guard let record = library.managedWorktree(forTaskID: requestedTaskID) else { return true }
    let taskID = record.taskID
    guard let head = record.archivedHead else {
      if FileManager.default.fileExists(atPath: record.path) { return true }
      archivedTaskDeletionError = "托管工作树目录缺失，无法恢复任务：\(record.path)"
      return false
    }
    do {
      let wasMissing = !FileManager.default.fileExists(atPath: record.path)
      try await WorktreeService.createOrRecover(record.checkout)
      let checkout = try await GitBranchService.snapshot(at: URL(fileURLWithPath: record.path))
      guard checkout.currentCommit == head else {
        throw AgentFailure(message: "工作树的提交与归档快照不一致，未覆盖目录。")
      }
      if wasMissing || record.archivedPruned == true {
        try await restoreArchivedChanges(record)
      }
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else {
        throw AgentFailure(message: "托管工作树记录已丢失。")
      }
      candidate.managedWorktrees[index].archivedHead = nil
      candidate.managedWorktrees[index].archivedStashCommit = nil
      candidate.managedWorktrees[index].archivedCopiedFiles = nil
      candidate.managedWorktrees[index].archivedPruned = false
      candidate.managedWorktrees[index].cleanupCompleted = nil
      try commitLibrary(candidate)
      _ = try? await GitReviewService.checked(
        ["update-ref", "-d", "refs/shipios/managed-archive/\(taskID)", head],
        at: URL(fileURLWithPath: record.source))
      if let stash = record.archivedStashCommit {
        _ = try? await GitReviewService.checked(
          ["update-ref", "-d", "refs/shipios/managed-archive-dirty/\(taskID)", stash],
          at: URL(fileURLWithPath: record.source))
      }
      ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID)
      archivedTaskDeletionError = nil
      return true
    } catch {
      archivedTaskDeletionError = "无法恢复托管工作树：\(error.localizedDescription)"
      return false
    }
  }

  private func restoreArchivedChanges(_ record: ManagedWorktree) async throws {
    let target = URL(fileURLWithPath: record.path)
    if let stash = record.archivedStashCommit {
      let worktreeMatches = try await LocalWorkspaceService.git(
        ["diff", "--quiet", stash, "--"], at: target).status == 0
      let indexMatches = try await LocalWorkspaceService.git(
        ["diff", "--quiet", "--cached", stash + "^2", "--"], at: target).status == 0
      if !worktreeMatches || !indexMatches {
        let worktreeClean = try await LocalWorkspaceService.git(
          ["diff", "--quiet", "HEAD", "--"], at: target).status == 0
        let indexClean = try await LocalWorkspaceService.git(
          ["diff", "--quiet", "--cached", "HEAD", "--"], at: target).status == 0
        guard worktreeClean, indexClean else {
          throw AgentFailure(message: "工作树已有其他已跟踪修改，未覆盖目录。")
        }
        _ = try await GitReviewService.checked(["stash", "apply", "--index", stash], at: target)
        let finalWorktree = try await LocalWorkspaceService.git(
          ["diff", "--quiet", stash, "--"], at: target).status == 0
        let finalIndex = try await LocalWorkspaceService.git(
          ["diff", "--quiet", "--cached", stash + "^2", "--"], at: target).status == 0
        guard finalWorktree, finalIndex else {
          throw AgentFailure(message: "已跟踪修改恢复后校验失败，快照仍保留。")
        }
      }
    }
    try ManagedSourceFiles.install(record.archivedCopiedFiles ?? [], dataRoot: dataRoot,
      taskID: record.taskID, target: target)
  }

  private func archivedCheckout(_ checkout: PermanentWorktree, head: String) -> PermanentWorktree {
    var result = PermanentWorktree(id: checkout.id, source: checkout.source, path: checkout.path,
      commonDirectory: checkout.commonDirectory, startingCommit: head,
      startingName: checkout.startingName, createdAt: checkout.createdAt, title: checkout.title)
    result.ready = checkout.ready
    return result
  }
}
