import Foundation

extension WorkspaceStore {
  var nextAttentionTask: WorkspaceTask? {
    guard libraryLoaded, !restoringLibrary, !busy else { return nil }
    let tasks = library.tasks
    guard !tasks.isEmpty else { return nil }
    let start = tasks.firstIndex(where: { $0.id == selectedTask?.id }).map { ($0 + 1) % tasks.count } ?? 0
    return (0..<tasks.count).lazy.map { tasks[(start + $0) % tasks.count] }.first {
      !$0.archived && !$0.runIDs.isEmpty && taskNeedsAttention($0) && canSelectTask($0)
    }
  }

  @discardableResult func openNextAttentionTask() async -> Bool {
    guard let target = nextAttentionTask else { return false }
    // Open the scope before consuming unread state; a missing project remains actionable.
    recordNavigation()
    guard await openTaskScope(target.project),
      let current = library.tasks.first(where: { $0.id == target.id }),
      !current.archived, taskNeedsAttention(current), canSelectTask(current)
    else { return false }
    presentedOverlay = nil
    showingBranchPicker = false
    showingModelPicker = false
    showingFind = false
    applyTaskSelection(current)
    await loadDetails()
    return true
  }

  func setTaskUnread(_ id: String, unread: Bool) {
    guard libraryLoaded, library.tasks.contains(where: { $0.id == id }) else { return }
    do {
      var candidate = library
      if unread { candidate.unreadTasks.insert(id) } else { candidate.unreadTasks.remove(id) }
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }

  func clearUnreadTasks() {
    guard libraryLoaded, !library.unreadTasks.isEmpty else { return }
    do {
      var candidate = library
      candidate.unreadTasks = []
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }

  private func taskNeedsAttention(_ task: WorkspaceTask) -> Bool {
    library.unreadTasks.contains(task.id) || mcpPendingApprovals.values.contains { task.runIDs.contains($0.runID) }
  }
}
