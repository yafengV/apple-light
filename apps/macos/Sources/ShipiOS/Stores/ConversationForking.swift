import Foundation

extension WorkspaceStore {
  var canForkConversation: Bool {
    guard !busy, let task = selectedTask, task.project == currentProjectKey else { return false }
    guard !library.managedWorktrees.contains(where: { $0.taskID == task.id }) else { return false }
    return (try? library.forkHistory(taskID: task.id, availableRuns: runs)) != nil
  }

  func canForkTaskWindow(_ taskID: String, through runID: String? = nil) -> Bool {
    guard libraryLoaded, !busy else { return false }
    guard !library.managedWorktrees.contains(where: { $0.taskID == taskID }) else { return false }
    return (try? library.forkHistory(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))) != nil
  }

  /// Persist a fork for the calling window without touching main-window navigation.
  func forkTaskWindowConversation(_ taskID: String, through runID: String? = nil,
    consumeCommand: Bool = false) throws -> WorkspaceTask {
    guard libraryLoaded, !busy else { throw AgentFailure(message: "请等待工作区完成当前操作后再分叉。") }
    guard !library.managedWorktrees.contains(where: { $0.taskID == taskID }) else {
      throw AgentFailure(message: "托管工作树任务需要创建独立检出后才能分叉。")
    }
    var candidate = library
    let fork = try candidate.forkConversation(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))
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
}
