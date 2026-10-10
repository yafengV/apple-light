import Foundation

extension WorkspaceStore {
  func validatePullRequestWatchTarget(_ item: ShipAutomation) -> Bool {
    guard item.watchedPullRequest != nil else { return true }
    guard libraryLoaded else { return false }
    guard let taskID = item.taskID,
      library.tasks.contains(where: { $0.id == taskID && !$0.archived && !$0.isTransient }) else {
      var paused = item
      paused.enabled = false
      _ = saveAutomation(paused)
      automationsError = "PR 监控任务已删除、归档或尚未关联，监控已暂停。"
      return false
    }
    return true
  }

  func pullRequestWatch(for request: GitHubPullRequest) -> ShipAutomation? {
    guard let url = request.validatedURL else { return nil }
    return automationPreferences.items.first {
      $0.watchedPullRequest?.validatedURL == url
    }
  }

  @discardableResult func startPullRequestWatch(_ request: GitHubPullRequest,
    taskID: String, root: URL,
    read: @escaping @Sendable (GitHubPullRequest, URL) async throws -> GitHubPRDetails = {
      try await GitHubPRService().details(for: $0, at: $1)
    }, runImmediately: Bool = true) async -> Bool {
    guard libraryLoaded, automationsLoaded, !library.gitPreferences.readOnlyReview,
      let url = request.validatedURL,
      library.tasks.contains(where: { $0.id == taskID && $0.project == root.path }),
      library.taskPullRequests[taskID]?.contains(where: { $0.validatedURL == url }) == true else {
      automationsError = "当前 PR 或自动化尚未就绪。"
      return false
    }
    do {
      let fresh = try await read(request, root)
      guard fresh.number == request.number, fresh.url == url.absoluteString,
        fresh.state.uppercased() == "OPEN" else {
        automationsError = "PR 已关闭、合并或已改变，请刷新后重试。"
        return false
      }
      guard libraryLoaded, automationsLoaded, !shuttingDown, !restoringLibrary,
        !library.gitPreferences.readOnlyReview, !taskForkIsReserved(taskID),
        library.tasks.contains(where: { $0.id == taskID && $0.project == root.path
          && !$0.archived && !$0.isTransient }),
        library.taskPullRequests[taskID]?.contains(where: { $0.validatedURL == url }) == true else {
        automationsError = "来源任务或 PR 已改变，监控未启动。"
        return false
      }
      let currentRequest = fresh.recorded(updating: request)
      guard let prompt = PullRequestWatchPrompt.make(currentRequest, preferences: library.gitPreferences) else {
        automationsError = "PR 地址无效。"
        return false
      }
      let now = Date()
      var watch = pullRequestWatch(for: request) ?? ShipAutomation()
      let previousLibrary = library
      var forked = false
      if let taskID = watch.taskID {
        guard library.tasks.contains(where: { $0.id == taskID && !$0.archived }) else {
          automationsError = "原监控任务已删除或归档，请恢复任务后重试。"
          return false
        }
      } else {
        var candidate = library
        let sourceRuns = taskWindowRuns(taskID)
        // Ordinary forks may start before the first turn; a new PR watch must
        // inherit at least one finished source run before creating a task.
        guard !(try candidate.forkHistory(taskID: taskID, availableRuns: sourceRuns)).isEmpty else {
          throw AgentFailure(message: "来源任务暂无已结束的回合，无法开始 PR 监控。")
        }
        let fork = try candidate.forkConversation(taskID: taskID,
          availableRuns: sourceRuns)
        guard let index = candidate.tasks.firstIndex(where: { $0.id == fork.id }) else {
          throw AgentFailure(message: "无法保存 PR 监控分叉任务。")
        }
        candidate.tasks[index].title = "监控并修复 PR #\(request.number)"
        candidate.taskPullRequests[fork.id] = [currentRequest]
        try commitLibrary(candidate)
        watch.taskID = fork.id
        forked = true
      }
      watch.name = "监控并修复 PR #\(request.number)"
      watch.prompt = prompt
      watch.project = root.path
      watch.projects = [root.path]
      watch.execution = .worktree
      watch.watchedPullRequest = currentRequest
      watch.cadence = .custom
      watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
      watch.scheduleAnchor = now
      watch.nextRun = watch.nextScheduledDate(after: now) ?? now.addingTimeInterval(600)
      watch.pauseReason = nil
      watch.pausedAt = nil
      watch.enabled = true
      watch.completedAt = nil
      guard saveAutomation(watch) else {
        if forked {
          do { try commitLibrary(previousLibrary) }
          catch { automationsError = "监控保存失败，分叉任务回滚也失败：\(error.localizedDescription)" }
        }
        return false
      }
      if runImmediately { Task { await self.runAutomation(watch.id) } }
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: "已启动自动修复", level: .info,
        taskID: taskID, watchAutomationID: watch.id, watchTaskID: watch.taskID)
      return true
    } catch {
      automationsError = "无法开始 PR 监控：\(error.localizedDescription)"
      return false
    }
  }

  func pausePullRequestWatch(_ request: GitHubPullRequest) {
    guard let watch = pullRequestWatch(for: request) else { return }
    var paused = watch
    paused.enabled = false
    if saveAutomation(paused) {
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: "已暂停自动修复", level: .info)
    } else {
      notices.show(id: "pr-watch:" + watch.id.uuidString,
        title: automationsError ?? "无法暂停自动修复。", level: .error)
    }
  }
}
