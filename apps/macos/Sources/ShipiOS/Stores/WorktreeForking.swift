import Foundation

extension WorkspaceStore {
  func canForkTaskToNewWorktree(_ id: String) -> Bool {
    guard !busy, !managedTaskPreparing, taskMenuForkingID == nil,
      activeLocalRun == nil, !taskForkIsReserved(id),
      let task = taskMenuTarget(id), !task.archived, !task.project.isEmpty,
      !handoffBlocksProject(task.project),
      library.isKnownProjectScope(task.project)
        || library.managedWorktrees.contains(where: { $0.path == task.project && $0.ready }),
      !library.managedWorktrees.contains(where: {
        $0.containsTask(id) && ($0.pendingForkSourceTaskID != nil || $0.archivedPruned == true)
      }) else { return false }
    return (try? library.forkHistory(taskID: id, availableRuns: taskWindowRuns(id))) != nil
  }

  /// Show a window-owned preparation page while the independent checkout is created.
  @discardableResult func forkTaskToNewWorktree(_ id: String, openTask: Bool = true,
    presentation: WorktreeForkPresentation? = nil, noticeBoard: WorkspaceNotices? = nil) async -> WorkspaceTask? {
    guard canForkTaskToNewWorktree(id), !Task.isCancelled,
      let sourceTask = library.tasks.first(where: { $0.id == id }) else { return nil }
    let history = taskWindowRuns(id)
    var frozen = library
    let fork: WorkspaceTask
    do { fork = try frozen.forkConversation(taskID: id, availableRuns: history) }
    catch { self.error = error.localizedDescription; return nil }
    let config = modelConfiguration(for: id)
    let permissions = runtimePermissions(for: id)
    let target = presentation ?? (openTask ? worktreeForkPresentation : nil)
    if target === worktreeForkPresentation { destination = .workspace; closeActivity() }
    let preparation = WorktreeForkPreparation(sourceTaskID: id, title: sourceTask.title,
      notices: noticeBoard ?? notices)
    return await runWorktreeForkPreparation(preparation, presentation: target) {
      await self.performWorktreeFork(sourceTask, frozenLibrary: frozen, fork: fork, config: config, permissions: permissions, preparation: preparation)
    }
  }

  private func performWorktreeFork(_ sourceTask: WorkspaceTask, frozenLibrary: WorkspaceLibrary,
    fork frozenFork: WorkspaceTask, config: ModelConfiguration, permissions: AgentRuntimePreferences,
    preparation: WorktreeForkPreparation) async -> WorkspaceTask? {
    let id = sourceTask.id
    taskMenuForkingID = id
    defer { taskMenuForkingID = nil }
    let source = URL(fileURLWithPath: sourceTask.project)
    var savedTaskID: String?
    var stashCommit: String?
    do {
      let snapshot = try await GitBranchService.snapshot(at: source)
      guard snapshot.canChange else { throw AgentFailure(message: "新工作树分叉需要 Git 仓库根目录。") }
      let inheritedEnvironment = library.managedWorktrees.first(where: {
        $0.containsTask(id) && $0.path == sourceTask.project
      })?.environment
      let environment = try await automationEnvironmentSnapshot(projectPath: sourceTask.project,
        selectionID: AutomationEnvironmentChoice.projectDefault, existing: inheritedEnvironment)
      let plan = try await WorktreeService.plan(snapshot: snapshot, branch: nil,
        title: sourceTask.title, parent: worktreeRoot)
      // A managed source can be pruned later. Keep Git lifecycle operations rooted in its stable
      // source repository, while copying files from the actual task checkout above.
      let stableSource = try stableWorktreeForkSource(sourceTask.project)
      guard try await WorktreeService.commonDirectory(at: URL(fileURLWithPath: stableSource)).path
        == plan.commonDirectory else { throw AgentFailure(message: "分叉来源的 Git 仓库已改变。") }
      let checkout = PermanentWorktree(id: plan.id, source: stableSource, path: plan.path,
        commonDirectory: plan.commonDirectory, startingCommit: plan.startingCommit,
        startingName: plan.startingName, createdAt: plan.createdAt, title: plan.title)
      let candidate = frozenLibrary
      var fork = frozenFork
      let needsNativeFork = config.apiProtocol == .codexResponses && fork.codexForkOrigin != nil
      if needsNativeFork {
        fork.modelSelection = .init(model: config.model, reasoning: config.reasoning,
          providerAccount: config.credentialAccount, apiProtocol: config.apiProtocol)
      }
      savedTaskID = fork.id
      preparation.taskID = fork.id
      preparation.path = checkout.path
      setWorktreeForkPhase("正在保存来源文件…")
      try Task.checkCancellation()
      let paths = try await ManagedSourceFiles.discover(at: source, excluding: dataRoot)
      let files = try ManagedSourceFiles.capture(paths, from: source, dataRoot: dataRoot, taskID: fork.id)
      let captured = try await GitReviewService.stashSnapshot(named: "shipios-fork-\(fork.id)", at: source)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !captured.isEmpty {
        guard captured.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
          throw AgentFailure(message: "无法保存分叉来源的未提交修改。")
        }
        _ = try await GitReviewService.checked(
          ["update-ref", "refs/shipios/managed-worktrees/\(fork.id)", captured], at: source)
        stashCommit = captured
      }
      let current = try await GitBranchService.snapshot(at: source)
      guard current.currentCommit == snapshot.currentCommit,
        current.currentReference == snapshot.currentReference,
        try await LocalWorkspaceService.git(
          ["diff", "--quiet", stashCommit ?? checkout.startingCommit, "--"], at: source).status == 0,
        try await LocalWorkspaceService.git(
          ["diff", "--quiet", "--cached", stashCommit.map { $0 + "^2" } ?? checkout.startingCommit, "--"], at: source).status == 0,
        try await ManagedSourceFiles.capturedSourceMatches(files, at: source, excluding: dataRoot),
        library.tasks.contains(where: {
          $0.id == id && $0.project == sourceTask.project && !$0.archived
            && $0.codexThreadID == sourceTask.codexThreadID
            && $0.codexWorkspacePath == sourceTask.codexWorkspacePath
            && $0.codexForkOrigin == sourceTask.codexForkOrigin
        }),
        !shuttingDown else {
        throw AgentFailure(message: "分叉期间来源状态已改变，请重试；来源文件已保留。")
      }
      // Merge only the frozen fork into the latest library: source runs and other windows may
      // have changed during Git/environment awaits. Persist task and checkout in one write.
      let copied = Set(fork.runIDs)
      let snapshots = candidate.forkRuns.filter { copied.contains($0.id) }
      var latest = library
      fork.project = checkout.path
      latest.tasks.insert(fork, at: 0)
      latest.taskRuntimePreferences[fork.id] = permissions
      latest.forkRuns.append(contentsOf: snapshots.map {
        AgentRun(id: $0.id, kind: $0.kind, project: checkout.path, status: $0.status,
          createdAt: $0.createdAt, updatedAt: $0.updatedAt, request: $0.request, result: $0.result)
      })
      for runID in copied {
        latest.forkRunOrigins[runID] = candidate.forkRunOrigins[runID]
        latest.notes[runID] = candidate.notes[runID]
        latest.runBranches[runID] = candidate.runBranches[runID]
        latest.runImages[runID] = candidate.runImages[runID]
        latest.runFiles[runID] = candidate.runFiles[runID]
      }
      var record = ManagedWorktree(taskID: fork.id, checkout: checkout)
      record.sourceStashCommit = stashCommit
      record.sourceCopiedFiles = files.isEmpty ? nil : files
      record.environment = environment
      record.pendingForkSourceTaskID = id
      record.nativeForkRequired = needsNativeFork
      record.forkSourcePath = sourceTask.project
      latest.managedWorktrees.append(record)
      var profile = latest.profiles[sourceTask.project] ?? BuildProfile()
      environment.apply(to: &profile)
      latest.profiles[checkout.path] = profile
      try Task.checkCancellation()
      try commitLibrary(latest)
      try await finishWorktreeFork(fork.id)
      return library.tasks.first { $0.id == fork.id }
    } catch {
      if let savedTaskID, !library.managedWorktrees.contains(where: { $0.taskID == savedTaskID }) {
        ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: savedTaskID)
        if let stashCommit {
          _ = try? await GitReviewService.checked(
            ["update-ref", "-d", "refs/shipios/managed-worktrees/\(savedTaskID)", stashCommit], at: source)
        }
      }
      reportWorktreeForkFailure(error, taskID: savedTaskID)
      return nil
    }
  }

  /// Resume the saved checkout/boundary/environment, never fork or capture the source again.
  func worktreeForkResumeBlocker(_ id: String) -> String? {
    if shuttingDown { return "应用正在关闭。" }
    if !libraryLoaded || restoringLibrary { return "正在恢复工作区，完成后将继续恢复此任务。" }
    if busy { return "正在切换或更新工作区，完成后将继续恢复此任务。" }
    if managedTaskPreparing { return "另一个工作树正在准备，完成后将继续恢复此任务。" }
    if activeLocalRun != nil { return "本地开发操作正在运行，完成后将继续恢复此任务。" }
    if taskForkIsReserved(id) { return "此任务的分支操作正在运行，完成后将继续恢复。" }
    guard library.tasks.contains(where: { $0.id == id && !$0.archived }),
      library.managedWorktrees.contains(where: { $0.containsTask(id) && $0.pendingForkSourceTaskID != nil })
      else { return "待恢复的工作树记录不可用。" }
    return nil
  }

  @discardableResult func resumeWorktreeFork(_ id: String, openTask: Bool = true,
    presentation: WorktreeForkPresentation? = nil, noticeBoard: WorkspaceNotices? = nil) async -> WorkspaceTask? {
    guard worktreeForkResumeBlocker(id) == nil,
      let task = library.tasks.first(where: { $0.id == id && !$0.archived })
      else { return nil }
    let target = presentation ?? (openTask ? worktreeForkPresentation : nil)
    if target === worktreeForkPresentation { destination = .workspace; closeActivity() }
    let record = library.managedWorktrees.first { $0.containsTask(id) && $0.pendingForkSourceTaskID != nil }
    let preparation = WorktreeForkPreparation(sourceTaskID: record?.pendingForkSourceTaskID ?? id,
      title: task.title, taskID: id, path: task.project, notices: noticeBoard ?? notices)
    return await runWorktreeForkPreparation(preparation, presentation: target) {
      await self.performResumeWorktreeFork(id)
    }
  }

  private func performResumeWorktreeFork(_ id: String) async -> WorkspaceTask? {
    do {
      try await finishWorktreeFork(id)
      return library.tasks.first { $0.id == id }
    } catch { reportWorktreeForkFailure(error, taskID: id); return nil }
  }

  private func finishWorktreeFork(_ id: String) async throws {
    try Task.checkCancellation()
    guard let saved = library.managedWorktrees.first(where: { $0.taskID == id }) else {
      throw AgentFailure(message: "分叉工作树记录不可用。")
    }
    setWorktreeForkPhase("正在创建工作树…")
    let record: ManagedWorktree
    if saved.ready {
      try await WorktreeService.createOrRecover(saved.checkout)
      record = saved
    } else { record = try await finishManagedWorktree(saved) }
    let target = try await GitBranchService.snapshot(at: URL(fileURLWithPath: record.path))
    guard record.setupCompleted == true || target.currentCommit == record.checkout.startingCommit else {
      throw AgentFailure(message: "分叉工作树的提交已改变，未覆盖该目录；请先检查后再继续创建。")
    }
    if record.sourceChangesApplied != true,
      record.sourceStashCommit != nil || !(record.sourceCopiedFiles ?? []).isEmpty {
      try await applyManagedSourceChanges(record)
    }
    try Task.checkCancellation()
    setWorktreeForkPhase("正在初始化分叉工作树…")
    try await runManagedWorktreeSetup(record)
    var createdNativeFork = false
    do {
      let native = try await createPendingWorktreeNativeFork(id)
      createdNativeFork = native != nil
      var candidate = library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == id }),
        candidate.managedWorktrees[index].ready,
        candidate.managedWorktrees[index].setupCompleted == true,
        candidate.tasks.contains(where: { $0.id == id }), !shuttingDown else {
        throw AgentFailure(message: "分叉工作树尚未准备完成，请继续创建。")
      }
      if let native, let taskIndex = candidate.tasks.firstIndex(where: { $0.id == id }) {
        candidate.tasks[taskIndex].codexThreadID = native.threadID
        candidate.tasks[taskIndex].codexWorkspacePath = native.workspace
      }
      try Task.checkCancellation()
      candidate.managedWorktrees[index].pendingForkSourceTaskID = nil
      try commitLibrary(candidate)
      worktreeError = nil
      if error?.hasPrefix("无法完成工作树分叉：") == true { error = nil }
      if activityError?.hasPrefix("无法完成工作树分叉：") == true { activityError = nil }
    } catch {
      if createdNativeFork { await Task { await self.codexTransport.discard(taskID: id) }.value }
      throw error
    }
  }

  private func reportWorktreeForkFailure(_ failure: Error, taskID: String?) {
    let retained = taskID.map { id in library.managedWorktrees.contains { $0.taskID == id } } ?? false
    let message = "无法完成工作树分叉：\(failure.localizedDescription)"
      + (retained ? "\n分叉已保存，可在任务菜单中继续创建。" : "")
    if failure is CancellationError || Task.isCancelled {
      activeWorktreeForkPreparation?.state = .cancelled
      return
    }
    activeWorktreeForkPreparation?.state = .failed(message)
    worktreeError = message
    let board = activeWorktreeForkPreparation?.notices ?? notices
    if board === notices {
      error = message
      if showingActivity { activityError = message }
    }
    board.show(id: "worktree-fork-\(taskID ?? "source")", title: message, level: .error, taskID: taskID)
  }

  private func stableWorktreeForkSource(_ path: String) throws -> String {
    var current = path
    var visited = Set<String>()
    while let record = library.managedWorktrees.first(where: { $0.path == current }) {
      guard visited.insert(current).inserted, record.ready, record.pendingHandoff == nil,
        record.pendingForkSourceTaskID == nil, record.archivedPruned != true else {
        throw AgentFailure(message: "来源工作树尚未准备完成或正在移交。")
      }
      current = record.source
    }
    return current
  }

  /// Completing a source turn during directory preparation must not strand its queued input
  /// or an already-approved goal continuation behind the temporary start gate.
  func resumeChatsAfterWorktreePreparation(_ ongoing: [String]) async {
    for runID in ongoing {
      guard let run = library.chatRuns.first(where: { $0.id == runID && $0.status == "succeeded" }),
        let owner = library.task(containing: run.id), owner.runIDs.last == runID,
        !taskForkIsReserved(owner.id), canStartChat(taskID: owner.id) else { continue }
      if let next = library.queuedMessages.first(where: { $0.taskID == owner.id }),
        !library.queuedMessages.contains(where: { $0.taskID == owner.id && codexSteeringMessages.contains($0.id) }) {
        await sendQueuedMessage(next)
      } else if let goal = library.goalSessions[owner.id], goal.status == .active,
        goal.lastRunID == runID {
        await startChat(GoalResponseParser.continuationPrompt, taskID: owner.id, mode: .goal)
      }
    }
  }
}
