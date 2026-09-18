import AppKit

struct ConversationRevealRequest: Equatable {
  let id = UUID()
  let runID: String
}

extension WorkspaceStore {
  var notificationPreferences: CompletionNotificationPreferences {
    get { library.notifications ?? CompletionNotificationPreferences() }
    set {
      guard libraryLoaded else {
        notifications.error = "工作区尚未完成加载，请稍后再修改通知设置。"
        return
      }
      do {
        var candidate = library
        candidate.notifications = newValue
        try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
        library = candidate
        notifications.error = nil
      } catch { notifications.error = error.localizedDescription }
    }
  }

  func observeCompletions(_ updated: [AgentRun], appActive: Bool? = nil) {
    for run in updated {
      guard let task = library.task(containing: run.id), task.project == run.project,
        completionTracker.completed(run)
      else { continue }
      let isVisible = (appActive ?? NSApp?.isActive ?? false) && destination == .workspace
        && presentedOverlay == nil && selectedTask?.id == task.id
      if !isVisible, !task.archived { setTaskUnread(task.id, unread: true) }
      let notice = CompletionNotice.turn(run, task: task, root: dataRoot)
      Task { [weak self] in
        guard let self else { return }
        await notifications.deliver(notice) {
          (self.notificationPreferences, NSApp?.isActive ?? false)
        }
      }
    }
  }

  @discardableResult func openNotification(_ target: NotificationDestination) async -> Bool {
    guard target.dataRoot == dataRoot.path,
      let task = library.tasks.first(where: { $0.id == target.taskID }),
      task.project == target.project, task.runIDs.contains(target.runID)
    else { return false }
    guard canSelectTask(task) else {
      error = "当前项目仍在运行，请等待结束后再打开通知中的任务。"
      return false
    }
    recordNavigation()
    guard await openTaskScope(task.project) else { return false }
    applyTaskSelection(task)
    showingFind = false
    selection = target.runID
    rememberProjectSelection()
    saveLibrary()
    conversationReveal = ConversationRevealRequest(runID: target.runID)
    return true
  }
}
