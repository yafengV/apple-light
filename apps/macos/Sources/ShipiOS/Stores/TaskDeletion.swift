import Foundation

extension WorkspaceStore {
  func canDeleteTaskFromMenu(_ id: String) -> Bool {
    guard canMutateArchive, activityArchiveRequest == nil, !managedTaskPreparing,
      let task = taskMenuTarget(id), !task.isTransient else { return false }
    return !library.managedWorktrees.contains {
      $0.containsTask(id) && $0.pendingHandoff != nil
    }
  }

  func requestTaskDeletion(_ id: String) {
    guard canDeleteTaskFromMenu(id) else { return }
    archivedTaskDeletionError = nil
    archiveDeletion = .init(kind: .task, taskIDs: [id])
  }

  /// The published confirmation owns a fixed target; a failed stop or write keeps it retryable.
  func performTaskDeletion(_ request: ArchiveDeletionRequest) async {
    do {
      guard request.kind == .task, request.taskIDs.count == 1,
        let id = request.taskIDs.first, libraryLoaded, !restoringLibrary,
        !shuttingDown, libraryReadError == nil else {
        throw AgentFailure(message: "工作区不可用，任务未删除。")
      }
      guard let task = library.tasks.first(where: { $0.id == id }), !task.isTransient,
        !managedTaskPreparing else { throw AgentFailure(message: "任务已变化，未删除。") }
      try await stopActivityTask(id)
      try Task.checkCancellation()
      let retained = library.managedWorktreesReleased(deleting: [id]).filter {
        $0.archivedPruned != true
          && FileManager.default.fileExists(atPath: $0.path)
      }
      for record in retained { try await WorktreeService.validateRetainedManaged(record) }
      guard archiveDeletion?.id == request.id, !shuttingDown, !restoringLibrary,
        libraryReadError == nil, !managedTaskPreparing,
        library.tasks.contains(where: { $0.id == id && !$0.isTransient }),
        activeRun(taskID: id) == nil else {
        throw AgentFailure(message: "任务状态已变化，未删除。")
      }
      if deleteTasks([id], archivedOnly: false, validatedManaged: Set(retained.map(\.taskID))) {
        await managedDeletionCleanupTask?.value
        archiveDeletion = nil
        notices.show(id: "task-delete-\(request.id)", title: "已永久删除任务", level: .success)
      }
    } catch { archivedTaskDeletionError = "无法删除任务：\(error.localizedDescription)" }
  }
}
