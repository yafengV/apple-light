import AppKit

struct ConversationRevealRequest: Equatable {
  let id = UUID()
  let runID: String
  var childRequestID: String? = nil
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
      if defersWatchInspectionCompletion(run) { continue }
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

  func notifyAttention(runID: String, kind: TaskNotificationKind, eventID: UUID, subagent: SubagentNotificationTarget? = nil) {
    guard kind != .completion,
      let run = library.chatRuns.first(where: { $0.id == runID }),
      let task = library.task(containing: runID), !task.archived,
      task.project == run.project else { return }
    let notice = CompletionNotice.attention(kind, eventID: eventID,
      run: run, task: task, root: dataRoot, subagent: subagent)
    Task { [weak self] in
      guard let self else { return }
      await notifications.deliver(notice) {
        var preferences = self.notificationPreferences
        if let subagent, !self.subagentElicitations(taskID: task.id, includeResolving: false).contains(where: {
          $0.agent.rootThreadID == subagent.rootThreadID && $0.agent.threadID == subagent.childThreadID
            && $0.request.id == subagent.requestToken
        }) {
          preferences.approvalAlertsEnabled = false; preferences.questionAlertsEnabled = false
        }
        return (preferences, NSApp?.isActive ?? false)
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
    destination = .workspace
    let revision = conversationForkNavigationRevision, activity = activitySession?.id
    let stillValid = { !self.shuttingDown && !Task.isCancelled
      && self.conversationForkNavigationRevision == revision && self.activitySession?.id == activity
      && self.presentedOverlay == nil && !self.hasSettingsConfirmation
      && self.library.tasks.contains { $0.id == target.taskID && $0.project == target.project
        && $0.runIDs.contains(target.runID) } }
    guard await openTaskScope(task.project, stillValid: stillValid), stillValid(),
      let latest = library.tasks.first(where: { $0.id == target.taskID }), canSelectTask(latest) else { return false }
    applyTaskSelection(latest)
    showingFind = false
    selection = target.runID
    rememberProjectSelection()
    saveLibrary()
    let childRequestID = target.subagent.flatMap { identity in
      subagentElicitations(taskID: task.id).first { $0.agent.rootThreadID == identity.rootThreadID
        && $0.agent.threadID == identity.childThreadID && $0.request.id == identity.requestToken }?.id
    }
    conversationReveal = ConversationRevealRequest(runID: target.runID, childRequestID: childRequestID)
    return true
  }
}
