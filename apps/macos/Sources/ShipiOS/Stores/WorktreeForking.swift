import Foundation

extension WorkspaceStore {
  func canForkTaskToNewWorktree(_ id: String) -> Bool {
    guard !busy, !managedTaskPreparing, taskMenuForkingID == nil,
      activeLocalRun == nil, !taskForkIsReserved(id),
      let task = taskMenuTarget(id), !task.archived, !task.project.isEmpty,
      !handoffBlocksProject(task.project),
      library.projects.contains(task.project)
        || library.managedWorktrees.contains(where: { $0.path == task.project && $0.ready }),
      !library.managedWorktrees.contains(where: {
        $0.containsTask(id) && ($0.pendingForkSourceTaskID != nil || $0.archivedPruned == true)
      }) else { return false }
    return (try? library.forkHistory(taskID: id, availableRuns: taskWindowRuns(id))) != nil
  }

  /// Snapshot the completed conversation and current checkout without moving the source task.
  @discardableResult func forkTaskToNewWorktree(_ id: String, openTask: Bool = true) async -> WorkspaceTask? {
    guard canForkTaskToNewWorktree(id),
      let sourceTask = library.tasks.first(where: { $0.id == id }) else { return nil }
    let history = taskWindowRuns(id)
    let boundary: String
    do { boundary = try library.forkHistory(taskID: id, availableRuns: history).last!.id }
    catch { self.error = error.localizedDescription; return nil }
    let ongoingChats = library.chatRuns.filter { modelTask(runID: $0.id) != nil }.map(\.id)
    managedTaskPreparing = true
    managedTaskPreparationMessage = "正在分叉到新工作树…"
    taskMenuForkingID = id
    busy = true
    defer {
      busy = false
      taskMenuForkingID = nil
      managedTaskPreparing = false
      managedTaskPreparationMessage = "正在创建工作树…"
      scheduleManagedLimitCleanup()
      Task { await resumeChatsAfterWorktreePreparation(ongoingChats) }
    }
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
      var candidate = library
      var fork = try candidate.forkConversation(taskID: id, through: boundary, availableRuns: history)
      savedTaskID = fork.id
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
        library.tasks.contains(where: { $0.id == id && $0.project == sourceTask.project && !$0.archived }),
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
      record.forkSourcePath = sourceTask.project
      latest.managedWorktrees.append(record)
      var profile = latest.profiles[sourceTask.project] ?? BuildProfile()
      environment.apply(to: &profile)
      latest.profiles[checkout.path] = profile
      try commitLibrary(latest)
      busy = false
      try await finishWorktreeFork(fork.id)
      if openTask { await revealWorktreeFork(fork) }
      return fork
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
  @discardableResult func resumeWorktreeFork(_ id: String, openTask: Bool = true) async -> WorkspaceTask? {
    guard libraryLoaded, !restoringLibrary, !shuttingDown, !busy, !managedTaskPreparing,
      activeLocalRun == nil, !taskForkIsReserved(id),
      let task = library.tasks.first(where: { $0.id == id && !$0.archived }),
      library.managedWorktrees.contains(where: { $0.containsTask(id) && $0.pendingForkSourceTaskID != nil })
      else { return nil }
    managedTaskPreparing = true
    managedTaskPreparationMessage = "正在继续创建分叉工作树…"
    let ongoingChats = library.chatRuns.filter { modelTask(runID: $0.id) != nil }.map(\.id)
    defer {
      managedTaskPreparing = false
      managedTaskPreparationMessage = "正在创建工作树…"
      scheduleManagedLimitCleanup()
      Task { await resumeChatsAfterWorktreePreparation(ongoingChats) }
    }
    do {
      try await finishWorktreeFork(id)
      if openTask { await revealWorktreeFork(task) }
      return task
    } catch { reportWorktreeForkFailure(error, taskID: id); return nil }
  }

  private func finishWorktreeFork(_ id: String) async throws {
    guard !busy, let saved = library.managedWorktrees.first(where: { $0.taskID == id }) else {
      throw AgentFailure(message: "分叉工作树记录不可用。")
    }
    busy = true
    defer { busy = false }
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
    managedTaskPreparationMessage = "正在初始化分叉工作树…"
    try await runManagedWorktreeSetup(record)
    var candidate = library
    guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == id }),
      candidate.managedWorktrees[index].ready,
      candidate.managedWorktrees[index].setupCompleted == true,
      candidate.tasks.contains(where: { $0.id == id }), !shuttingDown else {
      throw AgentFailure(message: "分叉工作树尚未准备完成，请继续创建。")
    }
    candidate.managedWorktrees[index].pendingForkSourceTaskID = nil
    try commitLibrary(candidate)
    worktreeError = nil
    error = nil
    if showingActivity { activityError = nil }
  }

  private func revealWorktreeFork(_ task: WorkspaceTask) async {
    if await selectTaskAwaitingScope(task) { action = .chat }
    else {
      let message = "分叉工作树已保存，但暂时无法打开。可从侧栏重新打开任务。"
      error = message
      if showingActivity { activityError = message }
      notices.show(id: "fork-open-\(task.id)", title: message, level: .error, taskID: task.id)
    }
  }

  private func reportWorktreeForkFailure(_ failure: Error, taskID: String?) {
    let retained = taskID.map { id in library.managedWorktrees.contains { $0.taskID == id } } ?? false
    let message = "无法完成工作树分叉：\(failure.localizedDescription)"
      + (retained ? "\n分叉已保存，可在任务菜单中继续创建。" : "")
    worktreeError = message
    error = message
    if showingActivity { activityError = message }
    notices.show(id: "worktree-fork-\(taskID ?? "source")", title: message, level: .error, taskID: taskID)
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
