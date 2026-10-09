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
    taskForkUsesWorktree(task) ? "在同一工作树中创建聊天分支" : "创建聊天分支"
  }

  /// A row forks its own latest history. Opening failure never discards the persisted fork.
  @discardableResult func forkTaskFromMenu(_ id: String) async -> WorkspaceTask? {
    guard canForkTaskFromMenu(id) else { return nil }
    taskMenuForkingID = id
    let pendingID = "fork-pending-\(id)"
    notices.show(id: pendingID, title: "正在创建聊天分支…", level: .pending, taskID: id)
    defer { taskMenuForkingID = nil; notices.completeAndDismiss(pendingID) }
    do {
      let fork = try await persistTaskMenuFork(id)
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
      if error is CancellationError || shuttingDown { return nil }
      self.error = error.localizedDescription
      if showingActivity { activityError = error.localizedDescription }
      notices.show(id: "fork-error-\(id)", title: "创建聊天分支失败",
        description: error.localizedDescription, level: .error, taskID: id)
      return nil
    }
  }
}
