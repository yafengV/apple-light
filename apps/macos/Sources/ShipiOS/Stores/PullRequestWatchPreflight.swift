import Foundation

extension WorkspaceStore {
  func pauseWatchAfterPreflightBlocker(_ expected: ShipAutomation,
    blocker: GitHubCLIError.Blocker, at date: Date) {
    guard libraryLoaded, automationsLoaded, !shuttingDown,
      var watch = automationPreferences.items.first(where: { $0.id == expected.id && $0.enabled }),
      watch.taskID == expected.taskID,
      watch.watchedPullRequest?.validatedURL == expected.watchedPullRequest?.validatedURL,
      let task = library.tasks.first(where: { $0.id == watch.taskID && !$0.archived && !$0.isTransient }),
      let request = watch.watchedPullRequest, let url = request.validatedURL else { return }
    watch.enabled = false
    watch.pauseReason = blocker.reason
    watch.pausedAt = date
    guard saveAutomation(watch) else {
      notices.show(id: "pr-watch:" + watch.id.uuidString,
        title: automationsError ?? "无法保存监控暂停状态。", level: .error)
      return
    }
    do {
      let response = """
        PR #\(request.number) 的监控已暂停，尚未开始模型修复。
        \(url.absoluteString)

        \(blocker.reason)

        \(blocker.question)
        处理后可在本任务继续回复，并恢复监控。
        """
      let time = date.timeIntervalSince1970 * 1000
      let run = AgentRun(id: UUID().uuidString, kind: "chat", project: task.project,
        status: "failed", createdAt: time, updatedAt: time,
        request: .object(["kind": .string("chat"), "conversation_kind": .string("watch_preflight"),
          "automation_id": .string(watch.id.uuidString),
          "prompt": .string("检查 PR #\(request.number) 的当前状态")]),
        result: .object(["response": .string(response),
          "message": .string("PR 状态检查需要人工处理。"),
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
      automationsError = "PR 监控已暂停：" + blocker.reason
      let owner = [task.forkOrigin?.taskID, task.id].compactMap { $0 }.first {
        pullRequestWatchContent(.pullRequestWatch(watch.id, task: task.id, owner: $0)) != nil
      }
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: "PR 监控需要人工处理", level: .warning,
        taskID: owner ?? task.id, watchAutomationID: owner == nil ? nil : watch.id,
        watchTaskID: owner == nil ? nil : task.id)
    } catch {
      automationsError = "PR 监控已暂停，但阻塞记录保存失败：\(error.localizedDescription)"
      notices.show(id: "pr-watch:" + watch.id.uuidString, title: automationsError!, level: .error)
    }
  }
}
