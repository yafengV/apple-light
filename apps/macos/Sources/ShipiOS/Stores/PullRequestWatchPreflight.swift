import Foundation

extension WorkspaceStore {
  func pauseWatchAfterPreflightBlocker(_ expected: ShipAutomation,
    blocker: GitHubCLIError.Blocker, at date: Date) {
    pauseWatchAfterPreflightResult(expected, outcome: .blocked(blocker), at: date)
  }

  func pauseWatchAfterPreflightResult(_ expected: ShipAutomation,
    outcome: PullRequestWatchPreflightOutcome, details: GitHubPRDetails? = nil, at date: Date) {
    guard libraryLoaded, automationsLoaded, !shuttingDown,
      var watch = automationPreferences.items.first(where: { $0.id == expected.id && $0.enabled }),
      watch.taskID == expected.taskID, watch.project == expected.project,
      watch.watchedPullRequest?.validatedURL == expected.watchedPullRequest?.validatedURL,
      let task = library.tasks.first(where: { $0.id == watch.taskID && !$0.archived && !$0.isTransient }),
      let original = watch.watchedPullRequest, let url = original.validatedURL else { return }
    if let details {
      guard details.number == original.number, details.url == url.absoluteString else { return }
      watch.watchedPullRequest = details.recorded(updating: original, at: date)
    }
    let request = watch.watchedPullRequest ?? original
    watch.enabled = false
    watch.pauseReason = outcome.reason
    watch.pausedAt = date
    // A paused PR heartbeat has not exhausted a finite calendar rule.
    watch.completedAt = nil
    guard saveAutomation(watch) else {
      notices.show(id: "pr-watch:" + watch.id.uuidString,
        title: automationsError ?? "无法保存监控暂停状态。", level: .error)
      return
    }
    do {
      let response = outcome.response(for: request)
      let time = date.timeIntervalSince1970 * 1000
      let run = AgentRun(id: UUID().uuidString, kind: "chat", project: task.project,
        status: outcome.needsInput ? "failed" : "succeeded", createdAt: time, updatedAt: time,
        request: .object(["kind": .string("chat"), "conversation_kind": .string("watch_preflight"),
          "automation_id": .string(watch.id.uuidString),
          "prompt": .string("检查 PR #\(request.number) 的当前状态")]),
        result: .object(["response": .string(response),
          "watch_preflight_outcome": .string(outcome.value),
          "message": outcome.needsInput ? .string("PR 状态检查需要人工处理。") : .null,
          "response_items": try ChatResponseItem.json([.message(id: UUID(), text: response)])]))
      var candidate = library
      candidate.attach(run, to: task.id, note: run.request["prompt"].text ?? "")
      candidate.chatRuns.append(run)
      candidate.unreadTasks.insert(task.id)
      try commitLibrary(candidate)
      let pending = watch.unresolvedRunIDs
      watch.lastRun = date
      watch.lastRunID = run.id
      watch.pendingRunIDs = pending.filter { $0 != run.id } + [run.id]
      guard saveAutomation(watch) else {
        throw AgentFailure(message: automationsError ?? "无法保存监控结果索引。")
      }
      automationsError = outcome.needsInput ? "PR 监控已暂停：" + outcome.reason : nil
      let owner = [task.forkOrigin?.taskID, task.id].compactMap { $0 }.first {
        pullRequestWatchContent(.pullRequestWatch(watch.id, task: task.id, owner: $0)) != nil
      }
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: outcome.needsInput ? "PR 监控需要人工处理" : "PR 监控已暂停",
        level: outcome.needsInput ? .warning : .success,
        taskID: owner ?? task.id, watchAutomationID: owner == nil ? nil : watch.id,
        watchTaskID: owner == nil ? nil : task.id)
    } catch {
      automationsError = "PR 监控已暂停，但\(outcome.recordName)保存失败：\(error.localizedDescription)"
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: automationsError!, level: .error)
    }
  }
}
