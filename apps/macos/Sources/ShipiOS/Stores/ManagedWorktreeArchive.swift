import Foundation

extension WorkspaceStore {
  func scheduleManagedArchiveCleanup(_ taskID: String) {
    let previous = managedArchiveCleanupTask
    managedArchiveCleanupTask = Task { @MainActor in
      await previous?.value
      await pruneArchivedManagedWorktree(taskID)
    }
  }

  private func pruneArchivedManagedWorktree(_ taskID: String) async {
    await Task.yield()
    guard let task = library.tasks.first(where: { $0.id == taskID && $0.archived }),
      let record = library.managedWorktrees.first(where: { $0.taskID == task.id }),
      activeRun(taskID: taskID) == nil else { return }
    let noticeID = "managed-archive-" + taskID
    if task.pinned {
      notices.show(id: noticeID, title: "置顶任务的工作树已保留", level: .info)
      return
    }
    if taskWindowResources.allObjects.contains(where: { $0.window != nil && $0.tasks[taskID] != nil }) {
      try? await Task.sleep(for: .milliseconds(300))
    }
    if taskWindowResources.allObjects.contains(where: { $0.window != nil && $0.tasks[taskID] != nil }) {
      notices.show(id: noticeID, title: "任务窗口仍在使用工作树，已保留目录", level: .info)
      return
    }
    if project?.path == record.path {
      await open(URL(fileURLWithPath: record.source))
      guard project?.path != record.path else {
        notices.show(id: noticeID, title: "项目仍在使用工作树，已保留目录", level: .info)
        return
      }
    }
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
      let status = try await GitReviewService.checked(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: checkout)
      let ignored = try await GitReviewService.checked(
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: checkout)
      guard status.isEmpty, ignored.isEmpty else {
        notices.show(id: noticeID, title: "工作树包含未保存文件，已保留目录", level: .info)
        return
      }
      let snapshot = try await GitBranchService.snapshot(at: checkout)
      guard let head = snapshot.currentCommit else {
        throw AgentFailure(message: "工作树没有可恢复的提交，已保留目录。")
      }
      let reference = "refs/shipios/managed-archive/" + taskID
      _ = try await GitReviewService.checked(["update-ref", reference, head],
        at: URL(fileURLWithPath: record.source))
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else { return }
      candidate.managedWorktrees[index].archivedHead = head
      candidate.managedWorktrees[index].checkout = archivedCheckout(record.checkout, head: head)
      try commitLibrary(candidate)
      let removed = try await WorktreeService.removeCleanManaged(candidate.managedWorktrees[index])
      guard removed else {
        notices.show(id: noticeID, title: "工作树在归档时发生修改，已保留目录", level: .info)
        return
      }
      var completed = library
      guard let completedIndex = completed.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else { return }
      completed.managedWorktrees[completedIndex].archivedPruned = true
      try commitLibrary(completed)
      notices.show(id: noticeID, title: "已保存提交并清理工作树，恢复任务时可重建", level: .info)
    } catch {
      notices.show(id: noticeID, title: "工作树已保留：\(error.localizedDescription)", level: .error)
    }
  }

  /// Recreate a pruned checkout before making its archived task visible again.
  func restoreManagedArchiveIfNeeded(_ taskID: String) async -> Bool {
    await managedArchiveCleanupTask?.value
    guard let record = library.managedWorktrees.first(where: { $0.taskID == taskID }) else { return true }
    guard let head = record.archivedHead else {
      if FileManager.default.fileExists(atPath: record.path) { return true }
      archivedTaskDeletionError = "托管工作树目录缺失，无法恢复任务：\(record.path)"
      return false
    }
    do {
      try await WorktreeService.createOrRecover(record.checkout)
      let checkout = try await GitBranchService.snapshot(at: URL(fileURLWithPath: record.path))
      guard checkout.currentCommit == head else {
        throw AgentFailure(message: "工作树的提交与归档快照不一致，未覆盖目录。")
      }
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == taskID }) else {
        throw AgentFailure(message: "托管工作树记录已丢失。")
      }
      candidate.managedWorktrees[index].archivedHead = nil
      candidate.managedWorktrees[index].archivedPruned = false
      try commitLibrary(candidate)
      _ = try? await GitReviewService.checked(
        ["update-ref", "-d", "refs/shipios/managed-archive/\(taskID)", head],
        at: URL(fileURLWithPath: record.source))
      archivedTaskDeletionError = nil
      return true
    } catch {
      archivedTaskDeletionError = "无法恢复托管工作树：\(error.localizedDescription)"
      return false
    }
  }

  private func archivedCheckout(_ checkout: PermanentWorktree, head: String) -> PermanentWorktree {
    var result = PermanentWorktree(id: checkout.id, source: checkout.source, path: checkout.path,
      commonDirectory: checkout.commonDirectory, startingCommit: head,
      startingName: checkout.startingName, createdAt: checkout.createdAt, title: checkout.title)
    result.ready = checkout.ready
    return result
  }
}
