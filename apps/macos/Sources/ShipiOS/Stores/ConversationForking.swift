import Foundation

extension WorkspaceStore {
  var canForkConversation: Bool {
    canForkConversation(through: nil)
  }

  func canForkConversation(through runID: String?) -> Bool {
    guard libraryLoaded, taskMenuForkingID == nil, !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      let task = selectedTask, !task.isTransient, !task.archived,
      !taskForkIsReserved(task.id),
      task.project == currentProjectKey else { return false }
    guard canForkInCurrentCheckout(task.id) else { return false }
    return (try? library.forkHistory(taskID: task.id, through: runID,
      availableRuns: taskWindowRuns(task.id))) != nil
  }

  func canForkTaskWindow(_ taskID: String, through runID: String? = nil) -> Bool {
    taskMenuForkingID == nil && forkSourceIsAvailable(taskID, through: runID)
  }

  /// The executing operation keeps its reservation while checking the live source.
  func forkSourceIsAvailable(_ taskID: String, through runID: String? = nil) -> Bool {
    guard libraryLoaded, !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      !taskForkIsReserved(taskID),
      library.tasks.contains(where: { $0.id == taskID && !$0.isTransient && !$0.archived }) else { return false }
    guard canForkInCurrentCheckout(taskID) else { return false }
    return (try? library.forkHistory(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))) != nil
  }

  /// Only imported/text history uses this path; native UI actions await the Core clone.
  func persistNonNativeFork(_ taskID: String, through runID: String? = nil,
    consumeCommand: Bool = false) throws -> WorkspaceTask {
    guard libraryLoaded, !busy, !shuttingDown, !restoringLibrary, !managedTaskPreparing,
      !taskForkIsReserved(taskID),
      library.tasks.contains(where: { $0.id == taskID && !$0.isTransient && !$0.archived }) else {
      throw AgentFailure(message: "任务不可用或正在归档/删除，请等待当前操作结束后再分叉。")
    }
    guard canForkInCurrentCheckout(taskID) else {
      throw AgentFailure(message: "工作树正在创建、清理或移交，请恢复工作树后再分叉。")
    }
    var candidate = library
    let fork = try candidate.forkConversation(taskID: taskID, through: runID,
      availableRuns: taskWindowRuns(taskID))
    candidate.shareManagedWorktree(sourceTaskID: taskID, fork: fork)
    if consumeCommand { candidate.drafts[taskID] = "" }
    try commitLibrary(candidate)
    if fork.project == currentProjectKey {
      let copied = Set(fork.runIDs)
      runs.append(contentsOf: candidate.forkRuns.filter { copied.contains($0.id) })
    }
    return fork
  }

  /// One lifecycle for sidebar, current chat and detached-window historical forks.
  func forkTaskWindowConversation(_ taskID: String, through runID: String? = nil,
    consumeCommand: Bool = false, expectedCommandDraft: String? = nil,
    revealInMainWindow: Bool = false, noticeBoard: WorkspaceNotices? = nil
  ) async throws -> WorkspaceTask {
    try Task.checkCancellation()
    guard canForkTaskWindow(taskID, through: runID) else {
      throw AgentFailure(message: "聊天来源不可用或已有分支正在创建，请稍后重试。")
    }
    let board = noticeBoard ?? notices
    let rawCommand = consumeCommand ? (expectedCommandDraft ?? library.drafts[taskID]) : nil
    let commandDraft = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.fork.token
      ? rawCommand : nil
    taskMenuForkingID = taskID
    let pendingID = "fork-pending-\(taskID)"
    board.show(id: pendingID, title: "正在创建聊天分支…", level: .pending, taskID: taskID)
    defer { taskMenuForkingID = nil; board.completeAndDismiss(pendingID) }
    do {
      let fork = try await persistConversationFork(taskID, through: runID, commandDraft: commandDraft)
      if revealInMainWindow {
        if await selectTaskAwaitingScope(fork) {
          action = .chat; error = nil
          if showingActivity { activityError = nil }
        } else {
          let message = "聊天分支已保存，但暂时无法打开其项目。可从侧栏重新打开任务。"
          error = message
          if showingActivity { activityError = message }
          board.show(id: "fork-open-\(fork.id)", title: message, level: .error, taskID: fork.id)
        }
      }
      return fork
    } catch {
      if !(error is CancellationError), !shuttingDown {
        board.show(id: "fork-error-\(taskID)", title: "创建聊天分支失败",
          description: error.localizedDescription, level: .error, taskID: taskID)
      }
      throw error
    }
  }

  /// Capture the clicked owner/command before scheduling work on the main actor.
  @discardableResult func requestConversationFork(through runID: String? = nil,
    consumeCommand: Bool = false) -> Task<WorkspaceTask?, Never>? {
    guard canForkConversation(through: runID), let task = selectedTask else { return nil }
    let commandDraft = consumeCommand ? library.drafts[task.id] : nil
    return Task { await forkConversation(taskID: task.id, through: runID,
      consumeCommand: consumeCommand, expectedCommandDraft: commandDraft) }
  }

  @discardableResult func forkConversation(taskID: String? = nil,
    through runID: String? = nil, consumeCommand: Bool = false,
    expectedCommandDraft: String? = nil
  ) async -> WorkspaceTask? {
    if let taskID, selectedTask?.id != taskID { return nil }
    guard canForkConversation(through: runID), let task = selectedTask else {
      error = "当前任务还没有可分叉的已结束回合。"
      return nil
    }
    do {
      let fork = try await forkTaskWindowConversation(task.id, through: runID,
        consumeCommand: consumeCommand, expectedCommandDraft: expectedCommandDraft,
        revealInMainWindow: true)
      if selectedTask?.id == fork.id { showingModelPicker = false }
      return fork
    } catch {
      if !(error is CancellationError), !shuttingDown { self.error = error.localizedDescription }
      return nil
    }
  }

  private func canForkInCurrentCheckout(_ id: String) -> Bool {
    guard let task = library.tasks.first(where: { $0.id == id }),
      !handoffBlocksProject(task.project) else { return false }
    guard let record = library.managedWorktree(forTaskID: id), record.path == task.project else {
      return true
    }
    return record.ready && record.pendingForkSourceTaskID == nil
      && record.pendingHandoff == nil && record.archivedHead == nil
      && record.archivedPruned != true && FileManager.default.fileExists(atPath: record.path)
  }

  /// Other windows cannot fork a target whose archive or deletion is being confirmed.
  func taskForkIsReserved(_ id: String) -> Bool {
    activityArchivingTaskIDs.contains(id)
      || activityArchiveRequest?.taskIDs.contains(id) == true
      || archiveDeletion?.taskIDs.contains(id) == true
  }
}
