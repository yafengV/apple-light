import Foundation

extension WorkspaceStore {
  func canForkTaskFromMenu(_ id: String) -> Bool {
    guard taskMenuForkingID == nil, let task = taskMenuTarget(id),
      canSelectTask(task) else { return false }
    return canForkTaskWindow(id)
  }

  func taskForkUsesWorktree(_ task: WorkspaceTask) -> Bool {
    library.isPermanentWorktree(task.project)
      || library.managedWorktrees.contains(where: { $0.path == task.project })
  }

  func taskMenuForkDestination(_ task: WorkspaceTask) -> String {
    taskForkUsesWorktree(task) ? "分叉到相同工作树" : "分叉到本地"
  }

  /// A row forks its own latest history. Opening failure never discards the persisted fork.
  @discardableResult func forkTaskFromMenu(_ id: String) async -> WorkspaceTask? {
    guard canForkTaskFromMenu(id) else { return nil }
    taskMenuForkingID = id
    defer { taskMenuForkingID = nil }
    do {
      let fork = try forkTaskWindowConversation(id)
      if await selectTaskAwaitingScope(fork) {
        action = .chat
        if showingActivity { activityError = nil }
        error = nil
      } else {
        let message = "分叉已保存，但暂时无法打开其项目。可从侧栏重新打开任务。"
        error = message
        if showingActivity { activityError = message }
        notices.show(id: "fork-open-\(fork.id)", title: message, level: .error, taskID: fork.id)
      }
      return fork
    } catch {
      self.error = error.localizedDescription
      if showingActivity { activityError = error.localizedDescription }
      return nil
    }
  }
}
