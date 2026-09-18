import Foundation

extension WorkspaceStore {
  var canForkConversation: Bool {
    !busy && selectedTask?.project == currentProjectKey
      && conversationRuns.first.map { !$0.isActive } == true
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
