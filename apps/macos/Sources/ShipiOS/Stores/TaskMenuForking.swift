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
    do {
      return try await forkTaskWindowConversation(id, revealInMainWindow: true)
    } catch {
      if error is CancellationError || shuttingDown { return nil }
      self.error = error.localizedDescription
      if showingActivity { activityError = error.localizedDescription }
      return nil
    }
  }
}
