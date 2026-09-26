import AppKit

extension WorkspaceStore {
  var hasLegacyWorktreeEnvironment: Bool {
    guard let profile = library.profiles[currentProjectKey] else { return false }
    return !profile.macOSSetupScript.isEmpty || !profile.macOSCleanupScript.isEmpty
      || !profile.actions.isEmpty
  }

  var newTaskEnvironmentSelection: String {
    get {
      if let taskID = library.pendingManagedDraftTaskIDs[currentProjectKey],
        let record = library.managedWorktrees.first(where: { $0.taskID == taskID }) {
        guard let snapshot = record.environment else { return WorktreeEnvironmentChoice.legacy }
        return snapshot.disabled ? WorktreeEnvironmentChoice.none :
          (snapshot.fileName ?? WorktreeEnvironmentChoice.legacy)
      }
      if let selected = library.newTaskEnvironmentSelections[currentProjectKey] { return selected }
      if environmentFiles.contains(where: { $0.fileName == environmentFileName && $0.error == nil }) {
        return environmentFileName
      }
      if hasLegacyWorktreeEnvironment {
        return WorktreeEnvironmentChoice.legacy
      }
      return WorktreeEnvironmentChoice.none
    }
    set {
      guard !currentProjectKey.isEmpty,
        library.pendingManagedDraftTaskIDs[currentProjectKey] == nil else { return }
      library.newTaskEnvironmentSelections[currentProjectKey] = newValue
      saveLibrary()
    }
  }

  var newTaskExecution: NewTaskExecution {
    get { library.newTaskExecutions[currentProjectKey] ?? .local }
    set {
      guard !currentProjectKey.isEmpty else { return }
      library.newTaskExecutions[currentProjectKey] = newValue
      saveLibrary()
    }
  }

  var newTaskStartingBranch: GitBranchChoice? {
    get { newTaskStartingBranches[currentProjectKey] }
    set {
      guard !currentProjectKey.isEmpty else { return }
      newTaskStartingBranches[currentProjectKey] = newValue
    }
  }

  var worktreeRoot: URL {
    GitBranchService.canonicalRoot(library.worktreeRoot.map { URL(fileURLWithPath: $0) }
      ?? dataRoot.appendingPathComponent("worktrees", isDirectory: true))
  }

  func beginWorktreeCreation(from path: String) {
    guard libraryLoaded, !busy, activeLocalRun == nil, library.projects.contains(path) else { return }
    worktreeSource = path
    worktreeError = nil
    setOverlay(.worktreeCreation, presented: true)
  }

  func setWorktreeRoot(_ url: URL?) {
    guard libraryLoaded, !busy else { return }
    do {
      var candidate = library
      candidate.worktreeRoot = url.map { GitBranchService.canonicalRoot($0).path }
      try commitLibrary(candidate)
      worktreeError = nil
    } catch { worktreeError = error.localizedDescription }
  }

  func chooseWorktreeRoot() {
    guard !busy, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择工作树根目录"
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    panel.directoryURL = worktreeRoot
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url {
        Task { @MainActor in self?.setWorktreeRoot(url) }
      }
    }
  }

  @discardableResult func createPermanentWorktree(snapshot: GitBranchSnapshot,
    branch: GitBranchChoice?, title: String) async -> PermanentWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      library.projects.contains(where: { GitBranchService.canonicalRoot(URL(fileURLWithPath: $0)) == snapshot.root }) else {
      worktreeError = "请等待当前任务完成，并从已添加的项目创建工作树。"
      return nil
    }
    busy = true; worktreeError = nil
    defer { busy = false }
    do {
      let record = try await WorktreeService.plan(snapshot: snapshot, branch: branch, title: title, parent: worktreeRoot)
      var candidate = library
      candidate.permanentWorktrees.append(record)
      // If this write fails no Git command creating a worktree has run yet.
      try commitLibrary(candidate)
      return try await finishWorktree(record)
    } catch {
      worktreeError = error.localizedDescription
      return nil
    }
  }

  @discardableResult func recoverWorktree(_ id: UUID) async -> PermanentWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      let record = library.permanentWorktrees.first(where: { $0.id == id && !$0.ready }) else { return nil }
    busy = true; worktreeError = nil
    defer { busy = false }
    do { return try await finishWorktree(record) }
    catch { worktreeError = error.localizedDescription; return nil }
  }

  private func finishWorktree(_ record: PermanentWorktree) async throws -> PermanentWorktree {
    try await WorktreeService.createOrRecover(record)
    var ready = PermanentWorktree(id: record.id, source: record.source,
      path: GitBranchService.canonicalRoot(URL(fileURLWithPath: record.path)).path,
      commonDirectory: GitBranchService.canonicalRoot(URL(fileURLWithPath: record.commonDirectory)).path,
      startingCommit: record.startingCommit, startingName: record.startingName,
      createdAt: record.createdAt, title: record.title)
    ready.ready = true
    var candidate = library
    candidate.permanentWorktrees.removeAll { $0.id == ready.id }
    candidate.permanentWorktrees.append(ready)
    candidate.visit(ready.path)
    candidate.projectNames[ready.path] = ready.title
    if let profile = library.profiles[ready.source] { candidate.profiles[ready.path] = profile }
    do { try commitLibrary(candidate) }
    catch { throw AgentFailure(message: "工作树已创建，但项目登记未保存。请在设置 → 工作树中恢复登记。路径：\(ready.path)\n\(error.localizedDescription)") }
    return ready
  }

  func openPermanentWorktree(_ record: PermanentWorktree) async {
    guard record.ready, !busy, activeLocalRun == nil else { return }
    presentedOverlay = nil
    recordNavigation()
    await open(URL(fileURLWithPath: record.path))
  }

  /// Reserve one detached checkout for a task. The pending record is durable before Git runs.
  @discardableResult func createManagedWorktree(snapshot: GitBranchSnapshot,
    branch: GitBranchChoice?, taskID: String,
    sourceStashCommit: String? = nil,
    sourceCopiedFiles: [ManagedSourceFile] = [],
    environment: ManagedEnvironmentSnapshot? = nil) async -> ManagedWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      UUID(uuidString: taskID) != nil,
      !library.managedWorktrees.contains(where: { $0.path == snapshot.root.path }),
      library.projects.contains(where: {
        GitBranchService.canonicalRoot(URL(fileURLWithPath: $0)) == snapshot.root
      }) else {
      worktreeError = "请从已添加的 Git 项目创建托管工作树任务。"
      return nil
    }
    if let existing = library.managedWorktrees.first(where: { $0.taskID == taskID }) {
      guard existing.source == snapshot.root.path else {
        worktreeError = "此任务已关联其他项目的工作树。"
        return nil
      }
      return existing.ready ? existing : await recoverManagedWorktree(taskID: taskID)
    }
    busy = true; worktreeError = nil
    defer { busy = false }
    do {
      let checkout = try await WorktreeService.plan(snapshot: snapshot, branch: branch,
        title: "托管任务", parent: worktreeRoot)
      var record = ManagedWorktree(taskID: taskID, checkout: checkout)
      record.sourceStashCommit = sourceStashCommit
      record.sourceCopiedFiles = sourceCopiedFiles.isEmpty ? nil : sourceCopiedFiles
      record.environment = environment
      var candidate = library
      candidate.managedWorktrees.append(record)
      try commitLibrary(candidate)
      return try await finishManagedWorktree(record)
    } catch {
      worktreeError = error.localizedDescription
      return nil
    }
  }

  @discardableResult func recoverManagedWorktree(taskID: String) async -> ManagedWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      let record = library.managedWorktrees.first(where: { $0.taskID == taskID }) else { return nil }
    if record.ready { return record }
    busy = true; worktreeError = nil
    defer { busy = false }
    do { return try await finishManagedWorktree(record) }
    catch { worktreeError = error.localizedDescription; return nil }
  }

  private func finishManagedWorktree(_ record: ManagedWorktree) async throws -> ManagedWorktree {
    try await WorktreeService.createOrRecover(record.checkout)
    let checkout = record.checkout
    var readyCheckout = PermanentWorktree(id: checkout.id, source: checkout.source,
      path: GitBranchService.canonicalRoot(URL(fileURLWithPath: checkout.path)).path,
      commonDirectory: GitBranchService.canonicalRoot(URL(fileURLWithPath: checkout.commonDirectory)).path,
      startingCommit: checkout.startingCommit, startingName: checkout.startingName,
      createdAt: checkout.createdAt, title: checkout.title)
    readyCheckout.ready = true
    var ready = record
    ready.checkout = readyCheckout
    var candidate = library
    candidate.managedWorktrees.removeAll { $0.taskID == ready.taskID }
    candidate.managedWorktrees.append(ready)
    do { try commitLibrary(candidate) }
    catch {
      throw AgentFailure(message: "托管工作树已创建，但状态尚未保存。请重试恢复。路径：\(ready.path)\n\(error.localizedDescription)")
    }
    scheduleManagedLimitCleanup()
    return ready
  }

  /// Replaying an already-applied stash is unsafe. Compare both the worktree and index with
  /// the captured stash trees so a crash after Git succeeds can be resumed without rewriting.
  func applyManagedSourceChanges(_ record: ManagedWorktree) async throws {
    let target = URL(fileURLWithPath: record.path)
    if let commit = record.sourceStashCommit {
      guard commit.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
        throw AgentFailure(message: "工作树修改快照 ID 无效。")
      }
      let worktreeMatches = try await LocalWorkspaceService.git(
        ["diff", "--quiet", commit, "--"], at: target).status == 0
      let indexMatches = try await LocalWorkspaceService.git(
        ["diff", "--quiet", "--cached", commit + "^2", "--"], at: target).status == 0
      if !worktreeMatches || !indexMatches {
        let status = try await GitReviewService.checked(
          ["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: target)
        guard status.isEmpty else {
          throw AgentFailure(message: "工作树已有修改，无法安全地重复传递来源修改。请在终端检查：\(record.path)")
        }
        _ = try await GitReviewService.checked(["stash", "apply", "--index", commit], at: target)
        let finalWorktree = try await LocalWorkspaceService.git(
          ["diff", "--quiet", commit, "--"], at: target).status == 0
        let finalIndex = try await LocalWorkspaceService.git(
          ["diff", "--quiet", "--cached", commit + "^2", "--"], at: target).status == 0
        guard finalWorktree, finalIndex else {
          throw AgentFailure(message: "来源修改已应用，但 Git 状态校验失败。请在终端检查：\(record.path)")
        }
      }
    }
    try ManagedSourceFiles.install(record.sourceCopiedFiles ?? [], dataRoot: dataRoot,
      taskID: record.taskID, target: target)
    var candidate = library
    guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == record.taskID }) else {
      throw AgentFailure(message: "工作树任务记录已丢失，请在终端检查：\(record.path)")
    }
    candidate.managedWorktrees[index].sourceChangesApplied = true
    try commitLibrary(candidate)
    if let commit = record.sourceStashCommit {
      _ = try? await GitReviewService.checked(
        ["update-ref", "-d", "refs/shipios/managed-worktrees/\(record.taskID)", commit],
        at: URL(fileURLWithPath: record.source))
    }
    ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: record.taskID)
  }

  func runManagedWorktreeSetup(_ record: ManagedWorktree) async throws {
    guard let current = library.managedWorktrees.first(where: { $0.taskID == record.taskID }),
      current.ready, current.sourceChangesApplied == true
        || (current.sourceStashCommit == nil && (current.sourceCopiedFiles ?? []).isEmpty) else {
      throw AgentFailure(message: "工作树仍在准备来源文件，无法运行初始化脚本。")
    }
    guard current.setupCompleted != true else { return }
    let script = current.environment?.macOSSetupScript
      ?? library.profiles[record.source]?.macOSSetupScript ?? ""
    if !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try await LocalEnvironmentScriptService.run(script, phase: .setup,
        source: URL(fileURLWithPath: record.source), worktree: URL(fileURLWithPath: record.path))
    }
    var candidate = library
    guard let index = candidate.managedWorktrees.firstIndex(where: { $0.taskID == record.taskID }) else {
      throw AgentFailure(message: "工作树任务记录已丢失，请在终端检查：\(record.path)")
    }
    candidate.managedWorktrees[index].setupCompleted = true
    try commitLibrary(candidate)
  }

  /// Convert a new-project draft to a one-task checkout before its first model turn.
  func prepareManagedWorktreeTask() async -> Bool {
    guard libraryLoaded, let source = project, connected, selectedTask == nil,
      newTaskExecution == .worktree, !busy, !managedTaskPreparing else { return false }
    managedTaskPreparing = true
    managedTaskPreparationMessage = "正在创建工作树…"
    defer {
      managedTaskPreparing = false
      managedTaskPreparationMessage = "正在创建工作树…"
      scheduleManagedLimitCleanup()
    }
    let sourcePath = source.path
    let sourceDraftKey = draftKey
    let submittedMode = chatMode
    var preparedTaskID: String?
    var protectedStashCommit: String?
    do {
      let config = modelConfiguration(for: nil)
      guard config.apiProtocol == .codexResponses else {
        throw AgentFailure(message: "工作树任务需要在设置 → 模型与 API 中选择 Codex Core · Responses。")
      }
      try config.validateEndpoint()
      guard !config.model.isEmpty else {
        throw AgentFailure(message: "请先在设置 → 模型与 API 中配置独立服务和模型。")
      }
      guard personalizationLoaded, memoryError == nil else {
        throw AgentFailure(message: "个人指令或记忆尚未加载完成，请在设置中检查。")
      }
      _ = try ModelKeychain.read(account: config.credentialAccount)
      let snapshot = try await GitBranchService.snapshot(at: source)
      guard snapshot.canChange, project?.path == sourcePath else {
        throw AgentFailure(message: "请打开 Git 仓库根目录后创建工作树任务。")
      }
      let startingBranch = newTaskStartingBranches[sourcePath]
      if let startingBranch,
        !snapshot.branches.contains(where: {
          $0.reference == startingBranch.reference && $0.commit == startingBranch.commit
        }) {
        throw AgentFailure(message: "起始分支已更新或被删除，请刷新分支列表后重试。")
      }
      let taskID = library.pendingManagedDraftTaskIDs[sourcePath] ?? UUID().uuidString
      preparedTaskID = taskID
      let existing = library.managedWorktrees.first(where: { $0.taskID == taskID })
      let environment: ManagedEnvironmentSnapshot
      if let captured = existing?.environment { environment = captured }
      else { environment = try await managedEnvironmentSnapshot(selectionID: newTaskEnvironmentSelection) }
      let copiesCurrentBranch = startingBranch == nil
        || (startingBranch?.reference == snapshot.currentReference
          && startingBranch?.commit == snapshot.currentCommit)
      var sourceStashCommit: String?
      var sourceCopiedFiles: [ManagedSourceFile] = []
      if existing == nil, copiesCurrentBranch {
        let paths = try await ManagedSourceFiles.discover(at: source, excluding: dataRoot)
        sourceCopiedFiles = try ManagedSourceFiles.capture(paths, from: source,
          dataRoot: dataRoot, taskID: taskID)
      }
      if existing == nil, snapshot.changedFiles > 0, copiesCurrentBranch {
        let captured = try await GitReviewService.checked(
          ["stash", "create", "shipios-managed-\(taskID)"], at: source)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard captured.isEmpty || captured.range(of: "^[0-9a-f]{40,64}$",
          options: .regularExpression) != nil else {
          throw AgentFailure(message: "无法保存来源项目的未提交修改，请在终端检查 Git 状态。")
        }
        if !captured.isEmpty {
          let reference = "refs/shipios/managed-worktrees/\(taskID)"
          _ = try await GitReviewService.checked(["update-ref", reference, captured], at: source)
          sourceStashCommit = captured
          protectedStashCommit = captured
        }
        guard sourceStashCommit != nil || !sourceCopiedFiles.isEmpty else {
          throw AgentFailure(message: "无法保存来源项目的未提交修改，请刷新项目后重试。")
        }
      }
      if library.pendingManagedDraftTaskIDs[sourcePath] == nil {
        var pending = library
        pending.pendingManagedDraftTaskIDs[sourcePath] = taskID
        try commitLibrary(pending)
      }
      guard let record = await createManagedWorktree(snapshot: snapshot, branch: startingBranch,
        taskID: taskID, sourceStashCommit: sourceStashCommit,
        sourceCopiedFiles: sourceCopiedFiles, environment: environment) else {
        throw AgentFailure(message: worktreeError ?? "无法创建托管工作树。")
      }
      if (record.sourceStashCommit != nil || !(record.sourceCopiedFiles ?? []).isEmpty),
        record.sourceChangesApplied != true {
        try await applyManagedSourceChanges(record)
      }
      managedTaskPreparationMessage = "正在初始化工作树…"
      try await runManagedWorktreeSetup(record)
      guard project?.path == sourcePath else {
        throw AgentFailure(message: "工作树已创建。请返回来源项目后重试发送草稿。")
      }
      var candidate = library
      if !candidate.tasks.contains(where: { $0.id == taskID }) {
        candidate.tasks.insert(WorkspaceTask(id: taskID, project: record.path,
          title: "新任务", runIDs: []), at: 0)
      }
      candidate.drafts[taskID] = candidate.drafts[sourceDraftKey]
      candidate.draftImages[taskID] = candidate.draftImages[sourceDraftKey]
      candidate.draftFiles[taskID] = candidate.draftFiles[sourceDraftKey]
      candidate.drafts[sourceDraftKey] = nil
      candidate.draftImages[sourceDraftKey] = nil
      candidate.draftFiles[sourceDraftKey] = nil
      candidate.projectSelections[record.path] = taskID
      candidate.pendingManagedDraftTaskIDs[sourcePath] = nil
      var taskProfile = candidate.profiles[sourcePath] ?? BuildProfile()
      record.environment?.apply(to: &taskProfile)
      candidate.profiles[record.path] = taskProfile
      try commitLibrary(candidate)
      await open(URL(fileURLWithPath: record.path))
      guard connected, project?.path == record.path else {
        throw AgentFailure(message: "工作树任务已保存，但无法连接该目录。请从侧栏重试。")
      }
      selection = taskID
      chatMode = submittedMode
      error = nil
      return true
    } catch {
      if let preparedTaskID,
        !library.managedWorktrees.contains(where: { $0.taskID == preparedTaskID }) {
        ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: preparedTaskID)
        if let protectedStashCommit {
          _ = try? await GitReviewService.checked(
            ["update-ref", "-d", "refs/shipios/managed-worktrees/\(preparedTaskID)",
              protectedStashCommit], at: source)
        }
      }
      self.error = error.localizedDescription
      return false
    }
  }
}
