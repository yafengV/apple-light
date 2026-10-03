import Foundation

extension WorkspaceStore {
  /// Prepare one scheduled run with the same durable managed-checkout machinery as a new task.
  func prepareAutomationWorktree(sourcePath: String, taskID: String,
    environmentSelection: String = WorktreeEnvironmentChoice.legacy,
    includeSourceChanges: Bool = true) async throws -> ManagedWorktree {
    try await prepareDetachedManagedWorktree(sourcePath: sourcePath, taskID: taskID,
      environmentSelection: environmentSelection, purpose: "计划任务",
      includeSourceChanges: includeSourceChanges)
  }

  /// Prepare a checkout without changing the currently selected workspace or its draft.
  func prepareDetachedManagedWorktree(sourcePath: String, taskID: String,
    environmentSelection: String, purpose: String,
    includeSourceChanges: Bool = true) async throws -> ManagedWorktree {
    let source = URL(fileURLWithPath: sourcePath)
    let snapshot = try await GitBranchService.snapshot(at: source)
    guard snapshot.canChange else {
      throw AgentFailure(message: "\(purpose)的工作树需要选择 Git 仓库根目录。")
    }
    let existing = library.managedWorktrees.first(where: { $0.taskID == taskID })
    var protectedStashCommit: String?
    do {
      let environment = try await automationEnvironmentSnapshot(
        projectPath: sourcePath, selectionID: environmentSelection,
        existing: existing?.environment)
      var sourceCopiedFiles: [ManagedSourceFile] = []
      var sourceStashCommit: String?
      if existing == nil && includeSourceChanges {
        let paths = try await ManagedSourceFiles.discover(at: source, excluding: dataRoot)
        sourceCopiedFiles = try ManagedSourceFiles.capture(paths, from: source,
          dataRoot: dataRoot, taskID: taskID)
        if snapshot.changedFiles > 0 {
          let captured = try await GitReviewService.stashSnapshot(
            named: "shipios-detached-\(taskID)", at: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard captured.isEmpty || captured.range(of: "^[0-9a-f]{40,64}$",
            options: .regularExpression) != nil else {
            throw AgentFailure(message: "无法保存\(purpose)来源项目的未提交修改。")
          }
          if !captured.isEmpty {
            _ = try await GitReviewService.checked(
              ["update-ref", "refs/shipios/managed-worktrees/\(taskID)", captured], at: source)
            sourceStashCommit = captured
            protectedStashCommit = captured
          }
          guard sourceStashCommit != nil || !sourceCopiedFiles.isEmpty else {
            throw AgentFailure(message: "无法保存\(purpose)来源项目的未提交修改。")
          }
        }
      }
      guard let record = await createManagedWorktree(snapshot: snapshot, branch: nil,
        taskID: taskID, sourceStashCommit: sourceStashCommit,
        sourceCopiedFiles: sourceCopiedFiles, environment: environment) else {
        throw AgentFailure(message: worktreeError ?? "无法创建\(purpose)工作树。")
      }
      if (record.sourceStashCommit != nil || !(record.sourceCopiedFiles ?? []).isEmpty),
        record.sourceChangesApplied != true {
        try await applyManagedSourceChanges(record)
      }
      try await runManagedWorktreeSetup(record)
      guard let ready = library.managedWorktrees.first(where: { $0.taskID == taskID && $0.ready }) else {
        throw AgentFailure(message: "\(purpose)工作树尚未准备完成。")
      }
      return ready
    } catch {
      if existing == nil, !library.managedWorktrees.contains(where: { $0.taskID == taskID }) {
        ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID)
        if let protectedStashCommit {
          _ = try? await GitReviewService.checked(
            ["update-ref", "-d", "refs/shipios/managed-worktrees/\(taskID)",
              protectedStashCommit], at: source)
        }
      }
      throw error
    }
  }
}
