import Foundation

extension WorkspaceStore {
  @discardableResult func openUsageRecord(taskID: String, runID: String? = nil) async -> Bool {
    guard let task = library.tasks.first(where: { $0.id == taskID }),
      runID.map({ task.runIDs.contains($0) }) ?? true
    else { return false }
    guard canSelectTask(task) else {
      error = "当前项目仍在运行，请等待结束后再打开该会话。"
      return false
    }
    recordNavigation()
    guard await openTaskScope(task.project) else { return false }
    applyTaskSelection(task)
    showingFind = false
    if let runID {
      selection = runID
      conversationReveal = ConversationRevealRequest(runID: runID)
    }
    rememberProjectSelection()
    saveLibrary()
    return true
  }
}
