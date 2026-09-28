import Foundation

extension WorkspaceStore {
  private func activityTaskCanArchive(_ task: WorkspaceTask) -> Bool {
    !task.archived && !task.isTransient && !task.runIDs.isEmpty && !managedTaskPreparing
      && !library.managedWorktrees.contains { $0.taskID == task.id && $0.pendingHandoff != nil }
  }

  var activityArchiveEligibleIDs: [String] {
    activityPriorityEntries.filter { activityTaskCanArchive($0.task) }.map(\.id)
  }

  var activityArchiveNeedsStop: Bool {
    activityArchiveRequest?.taskIDs.contains { activeRun(taskID: $0) != nil } == true
  }

  func requestActivityArchive() {
    guard showingActivity, canMutateArchive, !hasSettingsConfirmation,
      presentedOverlay == nil else { return }
    let ids = activityArchiveEligibleIDs
    guard !ids.isEmpty else { return }
    activityError = nil
    activityArchiveResult = nil
    activityArchiveRequest = .init(taskIDs: ids)
  }

  func dismissActivityArchive() {
    guard !archivingActivity else { return }
    activityArchiveRequest = nil
  }

  func confirmActivityArchive() async {
    guard let request = activityArchiveRequest, !archivingActivity else { return }
    archivingActivity = true
    activityArchivingTaskIDs = Set(request.taskIDs)
    defer { archivingActivity = false; activityArchivingTaskIDs = [] }
    await Task.yield()
    guard activityArchiveRequest?.id == request.id else { return }
    var result = ActivityArchiveResult()
    for id in request.taskIDs {
      do {
        try Task.checkCancellation()
        guard !shuttingDown, libraryLoaded, libraryReadError == nil else {
          throw AgentFailure(message: "工作区不可用，任务未归档。")
        }
        guard let task = library.tasks.first(where: { $0.id == id }) else {
          throw AgentFailure(message: "任务已不存在。")
        }
        if task.archived { result.archivedIDs.append(id); continue }
        guard activityTaskCanArchive(task) else {
          throw AgentFailure(message: "任务仍有工作树操作或其他未完成操作。")
        }
        try await stopActivityTask(id)
        try Task.checkCancellation()
        // Rebuild the candidate after stopping so concurrent updates to other tasks survive.
        guard !shuttingDown, let index = library.tasks.firstIndex(where: { $0.id == id }),
          activityTaskCanArchive(library.tasks[index]), activeRun(taskID: id) == nil else {
          throw AgentFailure(message: "任务状态已变化，未归档。")
        }
        var candidate = library
        candidate.tasks[index].archived = true
        candidate.tasks[index].archivedAt = Date()
        try commitLibrary(candidate)
        result.archivedIDs.append(id)
      } catch { result.failures[id] = error.localizedDescription }
    }
    if let selected = selectedTask?.id, result.archivedIDs.contains(selected) {
      newTask()
    }
    for id in result.archivedIDs where library.managedWorktrees.contains(where: { $0.taskID == id }) {
      scheduleManagedArchiveCleanup(id)
    }
    activityArchiveResult = result
    if !result.failures.isEmpty {
      activityError = request.taskIDs.compactMap { id in
        result.failures[id].map { message in
          (library.tasks.first(where: { $0.id == id })?.title ?? id) + "：" + message
        }
      }.joined(separator: "\n")
    }
    activityArchiveRequest = nil
    notices.show(id: "activity-archive-\(request.id)", title: result.message,
      level: result.failures.isEmpty ? .success : .error)
  }

  private func stopActivityTask(_ taskID: String) async throws {
    guard let run = activeRun(taskID: taskID) else { return }
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    if run.kind == "chat" {
      guard let running = modelTask(runID: run.id) else {
        throw AgentFailure(message: "无法确认正在运行的模型请求，任务已保留。")
      }
      running.cancel()
      while activeRun(taskID: taskID) != nil || modelTask(runID: run.id) != nil {
        guard !shuttingDown, ContinuousClock.now < deadline else {
          throw AgentFailure(message: "等待模型停止超时，任务已保留。")
        }
        try await Task.sleep(for: .milliseconds(25))
      }
    } else {
      guard connected, run.project == currentProjectKey else {
        throw AgentFailure(message: "任务的本地 Agent 未连接，任务已保留。")
      }
      _ = try await client.request("run.cancel", ["runId": .string(run.id)])
      while activeRun(taskID: taskID) != nil {
        guard !shuttingDown, ContinuousClock.now < deadline,
          connected, run.project == currentProjectKey else {
          throw AgentFailure(message: "无法确认本地任务已停止，任务已保留。")
        }
        let latest = try await client.request("run.get", ["runId": .string(run.id)]).decode(AgentRun.self)
        guard latest.id == run.id, latest.project == run.project else {
          throw AgentFailure(message: "本地 Agent 返回了其他任务，任务已保留。")
        }
        if let index = runs.firstIndex(where: { $0.id == latest.id }), runs[index].isActive {
          runs[index] = latest
          library.reconcile([latest], project: run.project)
        }
        if latest.isActive { try await Task.sleep(for: .milliseconds(50)) }
      }
    }
  }
}
