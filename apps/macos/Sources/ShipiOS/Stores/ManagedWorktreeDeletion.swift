import Foundation

extension WorkspaceStore {
  func scheduleManagedDeletionCleanup() {
    let previous = managedDeletionCleanupTask
    managedDeletionCleanupTask = Task { @MainActor in
      await previous?.value
      await cleanupPendingManagedWorktreeDeletions()
    }
  }

  /// The task and its managed ownership were removed in one library commit. Keep each
  /// cleanup record durable until both Git refs and the private file copy are gone.
  func cleanupPendingManagedWorktreeDeletions() async {
    for record in library.pendingManagedWorktreeDeletions {
      do {
        try await removeDeletedManagedResources(record)
        var candidate = library
        candidate.pendingManagedWorktreeDeletions.removeAll { $0.taskID == record.taskID }
        try commitLibrary(candidate)
      } catch {
        archivedTaskDeletionError = "工作树任务已删除，但私有快照清理未完成；重启后将重试：\(error.localizedDescription)"
        notices.show(id: "managed-delete-" + record.taskID,
          title: archivedTaskDeletionError ?? "工作树快照清理未完成", level: .error)
      }
    }
    if library.pendingManagedWorktreeDeletions.isEmpty,
      archivedTaskDeletionError?.hasPrefix("工作树任务已删除，但私有快照清理未完成") == true {
      archivedTaskDeletionError = nil
    }
  }

  private func removeDeletedManagedResources(_ record: ManagedWorktree) async throws {
    guard UUID(uuidString: record.taskID) != nil else {
      throw AgentFailure(message: "工作树任务 ID 无效。")
    }
    let source = URL(fileURLWithPath: record.source)
    if FileManager.default.fileExists(atPath: source.path) {
      guard GitBranchService.canonicalRoot(source).path == source.path else {
        throw AgentFailure(message: "原项目路径已改变，保留 Git 引用以供检查。")
      }
      let common = try await GitReviewService.checked(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: source)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard GitBranchService.canonicalRoot(URL(fileURLWithPath: common)).path ==
        GitBranchService.canonicalRoot(URL(fileURLWithPath: record.checkout.commonDirectory)).path else {
        throw AgentFailure(message: "原项目仓库已改变，保留 Git 引用以供检查。")
      }
      try await removeProtectedReference("refs/shipios/managed-worktrees/\(record.taskID)",
        expected: record.sourceStashCommit, at: source)
      try await removeProtectedReference("refs/shipios/managed-archive/\(record.taskID)",
        expected: record.archivedHead, at: source)
      try await removeProtectedReference("refs/shipios/managed-archive-dirty/\(record.taskID)",
        expected: record.archivedStashCommit, at: source)
    }
    try ManagedSourceFiles.removeSnapshotChecked(dataRoot: dataRoot, taskID: record.taskID)
  }

  private func removeProtectedReference(_ reference: String, expected: String?,
    at source: URL) async throws {
    guard let expected else { return }
    let current = try await LocalWorkspaceService.git(
      ["rev-parse", "--verify", reference + "^{commit}"], at: source)
    guard current.status == 0 else { return }
    guard current.text.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
      throw AgentFailure(message: "工作树保护引用已改变：\(reference)")
    }
    _ = try await GitReviewService.checked(["update-ref", "-d", reference, expected], at: source)
  }
}
