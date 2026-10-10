import Foundation

extension WorkspaceStore {
  var canForkConversation: Bool {
    canForkConversation(through: nil)
  }

  func canForkConversation(through runID: String?) -> Bool {
    guard libraryLoaded, taskMenuForkingID == nil, !busy, !shuttingDown, !restoringLibrary,
      !libraryRecoveryBlocksInteraction, !managedTaskPreparing else { return false }
    guard let task = selectedTask else {
      return selection == nil && runID == nil && (project == nil || connected) && activeLocalRun == nil
        && !handoffBlocksProject(currentProjectKey)
        && !library.managedWorktrees.contains(where: { $0.path == currentProjectKey })
    }
    guard !task.isTransient, !task.archived,
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
    let revealOrigin = currentTaskLocation
    let revealRevision = conversationForkNavigationRevision
    let revealActivity = activitySession?.id
    let revealContent = focusedWorkspaceTabID
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
        let stillValid = { !self.shuttingDown && !Task.isCancelled
          && self.conversationForkNavigationRevision == revealRevision
          && self.activitySession?.id == revealActivity }
        guard stillValid(), currentTaskLocation == revealOrigin,
          focusedWorkspaceTabID == revealContent else {
          board.show(id: "fork-ready-\(fork.id)", title: "聊天分支已创建",
            level: .success, taskID: fork.id)
          return fork
        }
        if await selectTaskAwaitingScope(fork, stillValid: stillValid) {
          action = .chat; error = nil
          if showingActivity { activityError = nil }
        } else if stillValid() {
          let message = "聊天分支已保存，但暂时无法打开其项目。可从侧栏重新打开任务。"
          error = message
          if showingActivity { activityError = message }
          board.show(id: "fork-open-\(fork.id)", title: message, level: .error, taskID: fork.id)
        } else {
          board.show(id: "fork-ready-\(fork.id)", title: "聊天分支已创建",
            level: .success, taskID: fork.id)
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
    guard canForkConversation(through: runID) else { return nil }
    let taskID = selectedTask?.id, owner = draftKey
    let commandDraft = consumeCommand ? library.drafts[owner] : nil
    return Task {
      guard taskID != nil || (selectedTask == nil && draftKey == owner) else { return nil }
      return await forkConversation(taskID: taskID, through: runID,
        consumeCommand: consumeCommand, expectedCommandDraft: commandDraft)
    }
  }

  /// Save an unsent source only when the user explicitly forks it. Keeping its
  /// own task ID makes drafts recoverable even if Core initialization fails.
  private func materializeUnsentForkSource() async throws -> WorkspaceTask {
    guard selectedTask == nil, canForkConversation else {
      throw AgentFailure(message: "新聊天来源已改变，请重试。")
    }
    if project != nil, newTaskExecution == .worktree {
      guard await prepareManagedWorktreeTask(), let task = selectedTask else {
        throw AgentFailure(message: error ?? "无法准备来源工作树，请重试。")
      }
      return task
    }
    let owner = draftKey, config = modelConfiguration(for: nil)
    if config.apiProtocol == .codexResponses {
      try config.validateEndpoint()
      guard !config.model.isEmpty else { throw AgentFailure(message: "请配置独立模型服务后重试。") }
    }
    var candidate = library
    var source = WorkspaceTask(id: UUID().uuidString, project: currentProjectKey,
      title: "新任务", runIDs: [])
    if !config.model.isEmpty {
      source.modelSelection = .init(model: config.model, reasoning: config.reasoning,
        providerAccount: config.credentialAccount, apiProtocol: config.apiProtocol)
    }
    candidate.tasks.insert(source, at: 0)
    candidate.drafts[source.id] = candidate.drafts.removeValue(forKey: owner)
    candidate.draftImages[source.id] = candidate.draftImages.removeValue(forKey: owner)
    candidate.draftFiles[source.id] = candidate.draftFiles.removeValue(forKey: owner)
    candidate.pullRequestCheckDrafts[source.id] = candidate.pullRequestCheckDrafts.removeValue(forKey: owner)
    candidate.taskRuntimePreferences[source.id] = candidate.newTaskRuntimePreferences.removeValue(forKey: owner)
      ?? candidate.agentRuntimePreferences
    try commitLibrary(candidate)
    selectTask(source)
    return source
  }

  @discardableResult func forkConversation(taskID: String? = nil,
    through runID: String? = nil, consumeCommand: Bool = false,
    expectedCommandDraft: String? = nil
  ) async -> WorkspaceTask? {
    if let taskID, selectedTask?.id != taskID { return nil }
    guard canForkConversation(through: runID) else {
      error = "当前聊天暂时无法创建分支，请等待操作结束或恢复工作树后重试。"
      return nil
    }
    do {
      let task: WorkspaceTask
      if let selectedTask { task = selectedTask }
      else { task = try await materializeUnsentForkSource() }
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
