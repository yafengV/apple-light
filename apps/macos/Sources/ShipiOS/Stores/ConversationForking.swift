import Foundation

extension WorkspaceStore {
  var canForkConversation: Bool {
    guard !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      let task = selectedTask, !task.isTransient, !task.archived,
      !taskForkIsReserved(task.id),
      task.project == currentProjectKey else { return false }
    guard canForkInCurrentCheckout(task.id) else { return false }
    return (try? library.forkHistory(taskID: task.id, availableRuns: runs)) != nil
  }

  func canForkTaskWindow(_ taskID: String, through runID: String? = nil) -> Bool {
    guard libraryLoaded, !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      !taskForkIsReserved(taskID),
      library.tasks.contains(where: { $0.id == taskID && !$0.isTransient && !$0.archived }) else { return false }
    guard canForkInCurrentCheckout(taskID) else { return false }
    return (try? library.forkHistory(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))) != nil
  }

  /// Persist a fork for the calling window without touching main-window navigation.
  func forkTaskWindowConversation(_ taskID: String, through runID: String? = nil,
    consumeCommand: Bool = false) throws -> WorkspaceTask {
    guard libraryLoaded, !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      !taskForkIsReserved(taskID),
      library.tasks.contains(where: { $0.id == taskID && !$0.isTransient && !$0.archived }) else {
      throw AgentFailure(message: "任务不可用或正在归档/删除，请等待当前操作结束后再分叉。")
    }
    guard canForkInCurrentCheckout(taskID) else {
      throw AgentFailure(message: "工作树正在创建、清理或移交，请恢复工作树后再分叉。")
    }
    var candidate = library
    let fork = try candidate.forkConversation(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))
    candidate.shareManagedWorktree(sourceTaskID: taskID, fork: fork)
    if consumeCommand { candidate.drafts[taskID] = "" }
    try commitLibrary(candidate)
    if fork.project == currentProjectKey {
      let copied = Set(fork.runIDs)
      runs.append(contentsOf: candidate.forkRuns.filter { copied.contains($0.id) })
    }
    return fork
  }

  @discardableResult func forkConversation(
    through runID: String? = nil, consumeCommand: Bool = false
  ) -> WorkspaceTask? {
    guard canForkConversation, let task = selectedTask else {
      error = "当前任务还没有可分叉的已结束回合。"
      return nil
    }
    do {
      var candidate = library
      let fork = try candidate.forkConversation(
        taskID: task.id, through: runID, availableRuns: runs)
      candidate.shareManagedWorktree(sourceTaskID: task.id, fork: fork)
      if consumeCommand { candidate.drafts[task.id] = "" }
      // Persist before switching tasks, so a failed write cannot create a ghost fork.
      candidate.projectSelections[task.project] = fork.runIDs.last
      try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
      library = candidate
      let newIDs = Set(fork.runIDs)
      runs.append(contentsOf: candidate.forkRuns.filter { newIDs.contains($0.id) })
      error = nil
      selectTask(fork)
      action = .chat
      showingModelPicker = false
      return fork
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  private func canForkInCurrentCheckout(_ id: String) -> Bool {
    guard let task = library.tasks.first(where: { $0.id == id }),
      !handoffBlocksProject(task.project) else { return false }
    guard let record = library.managedWorktree(forTaskID: id), record.path == task.project else {
      return true
    }
    return record.ready && record.pendingForkSourceTaskID == nil
      && record.pendingHandoff == nil && record.archivedHead == nil
      && record.archivedPruned != true && FileManager.default.fileExists(atPath: record.path)
  }

  /// Other windows cannot fork a target whose archive or deletion is being confirmed.
  func taskForkIsReserved(_ id: String) -> Bool {
    activityArchivingTaskIDs.contains(id)
      || activityArchiveRequest?.taskIDs.contains(id) == true
      || archiveDeletion?.taskIDs.contains(id) == true
  }
}
