import Foundation

extension WorkspaceStore {
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
      guard let prompt = PullRequestWatchPrompt.make(request, preferences: library.gitPreferences) else {
        automationsError = "PR 地址无效。"
        return false
      }
      let now = Date()
      var watch = pullRequestWatch(for: request) ?? ShipAutomation()
      watch.name = "监控并修复 PR #\(request.number)"
      watch.prompt = prompt
      watch.project = root.path
      watch.projects = [root.path]
      watch.execution = .worktree
      watch.watchedPullRequest = fresh.recorded(updating: request)
      watch.cadence = .custom
      watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
      watch.scheduleAnchor = now
      watch.nextRun = watch.nextScheduledDate(after: now) ?? now.addingTimeInterval(600)
      watch.enabled = true
      watch.completedAt = nil
      guard saveAutomation(watch) else { return false }
      if runImmediately { Task { await self.runAutomation(watch.id) } }
      return true
    } catch {
      automationsError = "无法开始 PR 监控：\(error.localizedDescription)"
      return false
    }
  }

  func pausePullRequestWatch(_ request: GitHubPullRequest) {
    guard let watch = pullRequestWatch(for: request) else { return }
    setAutomationEnabled(false, id: watch.id)
  }
}
