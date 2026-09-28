import Foundation

extension WorkspaceLibrary {
  func managedWorktree(forTaskID id: String) -> ManagedWorktree? {
    managedWorktrees.first { $0.containsTask(id) }
  }

  func managedTasks(for record: ManagedWorktree) -> [WorkspaceTask] {
    tasks.filter { record.containsTask($0.id) }
  }

  /// Only the last task deletion releases a shared checkout and its private resources.
  func managedWorktreesReleased(deleting ids: Set<String>) -> [ManagedWorktree] {
    managedWorktrees.filter { record in
      let members = Set(managedTasks(for: record).map(\.id))
      return !members.isDisjoint(with: ids) && members.isSubset(of: ids)
    }
  }

  mutating func shareManagedWorktree(sourceTaskID: String, fork: WorkspaceTask) {
    guard let index = managedWorktrees.firstIndex(where: {
      $0.containsTask(sourceTaskID) && $0.path == fork.project
    }) else { return }
    var ids = managedWorktrees[index].associatedTaskIDs
    ids.insert(fork.id)
    ids.remove(managedWorktrees[index].taskID)
    managedWorktrees[index].sharedTaskIDs = ids.sorted()
  }
}
