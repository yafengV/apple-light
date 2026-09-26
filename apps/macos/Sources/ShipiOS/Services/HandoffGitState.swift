import Foundation

/// An immutable, protected copy of one checkout's staged, unstaged and selected local files.
/// The caller must persist this record before applying it or clearing the source.
struct HandoffGitSnapshot: Codable, Equatable {
  let taskID: String
  let sourcePath: String
  let targetPath: String
  let head: String
  let stashCommit: String?
  let copiedFiles: [ManagedSourceFile]

  var protectedReference: String { "refs/shipios/handoff-dirty/" + taskID }
}

enum HandoffGitState {
  static func capture(taskID: String, source: URL, target: URL,
    dataRoot: URL) async throws -> HandoffGitSnapshot {
    guard UUID(uuidString: taskID) != nil else {
      throw AgentFailure(message: "工作树任务 ID 无效。")
    }
    let from = try await GitBranchService.snapshot(at: source)
    let to = try await GitBranchService.snapshot(at: target)
    guard from.canChange, to.canChange,
      try await commonDirectory(at: from.root) == commonDirectory(at: to.root),
      from.currentCommit == to.currentCommit,
      let head = from.currentCommit, from.root != to.root else {
      throw AgentFailure(message: "两边检出需要位于同一提交，才能移交未提交修改。")
    }
    guard !ManagedSourceFiles.snapshotExists(dataRoot: dataRoot, taskID: taskID) else {
      throw AgentFailure(message: "上一次工作树文件快照仍在，先完成或检查上次移交。")
    }
    let reference = "refs/shipios/handoff-dirty/" + taskID
    let protected = try await LocalWorkspaceService.git(
      ["rev-parse", "--verify", reference + "^{commit}"], at: from.root)
    guard protected.status != 0 else {
      throw AgentFailure(message: "上一次 Git 移交快照仍在，先完成或检查上次移交。")
    }
    let paths = try await ManagedSourceFiles.discover(at: from.root, excluding: dataRoot)
    let targetPaths = try await ManagedSourceFiles.discover(at: to.root, excluding: dataRoot)
    guard Set(targetPaths).isSubset(of: Set(paths)),
      try await trackedClean(at: to.root) else {
      throw AgentFailure(message: "目标检出已有其他修改，未覆盖目标目录。")
    }
    var files: [ManagedSourceFile] = []
    var stash: String?
    do {
      files = try ManagedSourceFiles.capture(paths, from: from.root,
        dataRoot: dataRoot, taskID: taskID)
      guard try ManagedSourceFiles.canInstall(files, dataRoot: dataRoot,
        taskID: taskID, target: to.root) else {
        throw AgentFailure(message: "两个检出的本地文件冲突，未覆盖目标目录。")
      }
      let captured = try await GitReviewService.checked(
        ["stash", "create", "shipios-handoff-" + taskID], at: from.root)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !captured.isEmpty {
        guard validCommitID(captured) else {
          throw AgentFailure(message: "Git 移交快照 ID 无效。")
        }
        _ = try await GitReviewService.checked(["update-ref", reference, captured], at: from.root)
        stash = captured
      }
      guard stash != nil || !files.isEmpty else {
        throw AgentFailure(message: "没有可移交的未提交修改。")
      }
      let snapshot = HandoffGitSnapshot(taskID: taskID, sourcePath: from.root.path,
        targetPath: to.root.path, head: head, stashCommit: stash, copiedFiles: files)
      guard try await trackedMatches(snapshot, at: from.root),
        try await ManagedSourceFiles.capturedSourceMatches(files, at: from.root,
          excluding: dataRoot) else {
        throw AgentFailure(message: "来源检出在创建移交快照时发生变化，未清理原目录。")
      }
      return snapshot
    } catch {
      if let stash {
        _ = try? await GitReviewService.checked(["update-ref", "-d", reference, stash], at: from.root)
      }
      if !files.isEmpty { ManagedSourceFiles.removeSnapshot(dataRoot: dataRoot, taskID: taskID) }
      throw error
    }
  }

  /// Safe to retry after a crash between Git apply and copying local-only files.
  static func apply(_ snapshot: HandoffGitSnapshot, dataRoot: URL) async throws {
    try await validate(snapshot)
    let target = URL(fileURLWithPath: snapshot.targetPath)
    guard try await commit(at: target) == snapshot.head,
      try ManagedSourceFiles.canInstall(snapshot.copiedFiles, dataRoot: dataRoot,
        taskID: snapshot.taskID, target: target) else {
      throw AgentFailure(message: "目标检出或本地文件已改变，未继续移交。")
    }
    let targetPaths = try await ManagedSourceFiles.discover(at: target, excluding: dataRoot)
    guard Set(targetPaths).isSubset(of: Set(snapshot.copiedFiles.map(\.path))) else {
      throw AgentFailure(message: "目标检出新增了本地文件，未继续移交。")
    }
    if let stash = snapshot.stashCommit,
      try await !trackedMatches(snapshot, at: target) {
      guard try await trackedClean(at: target) else {
        throw AgentFailure(message: "目标检出已有其他已跟踪修改，未覆盖目标目录。")
      }
      _ = try await GitReviewService.checked(["stash", "apply", "--index", stash], at: target)
    }
    try ManagedSourceFiles.install(snapshot.copiedFiles, dataRoot: dataRoot,
      taskID: snapshot.taskID, target: target)
    guard try await destinationMatches(snapshot) else {
      throw AgentFailure(message: "目标检出应用移交快照后校验失败，来源修改仍保留。")
    }
  }

  static func destinationMatches(_ snapshot: HandoffGitSnapshot) async throws -> Bool {
    let target = URL(fileURLWithPath: snapshot.targetPath)
    guard try await commit(at: target) == snapshot.head else { return false }
    guard try await trackedMatches(snapshot, at: target) else { return false }
    return try ManagedSourceFiles.installedMatches(snapshot.copiedFiles, at: target)
  }

  /// Only clear the source after an independently verified destination has the full snapshot.
  /// A retry accepts a source already reset to HEAD and a partially removed file set.
  static func clearSource(_ snapshot: HandoffGitSnapshot, dataRoot: URL) async throws {
    try await validate(snapshot)
    guard try await destinationMatches(snapshot) else {
      throw AgentFailure(message: "目标检出尚未完整保存来源修改，未清理来源目录。")
    }
    let source = URL(fileURLWithPath: snapshot.sourcePath)
    guard try await commit(at: source) == snapshot.head,
      try await ManagedSourceFiles.capturedSourceMatches(snapshot.copiedFiles,
        at: source, excluding: dataRoot, allowMissing: true) else {
      throw AgentFailure(message: "来源检出在移交期间改变，未清理原目录。")
    }
    if try await !trackedClean(at: source) {
      guard try await trackedMatches(snapshot, at: source) else {
        throw AgentFailure(message: "来源已跟踪文件在移交期间改变，未清理原目录。")
      }
      _ = try await GitReviewService.checked(["reset", "--hard", "HEAD"], at: source)
    }
    try await ManagedSourceFiles.removeCaptured(snapshot.copiedFiles, from: source,
      excluding: dataRoot)
    guard try await trackedClean(at: source),
      try await ManagedSourceFiles.discover(at: source, excluding: dataRoot).isEmpty else {
      throw AgentFailure(message: "来源检出清理后仍有未提交修改，请检查原目录。")
    }
  }

  static func release(_ snapshot: HandoffGitSnapshot, dataRoot: URL) async throws {
    try await validate(snapshot)
    let source = URL(fileURLWithPath: snapshot.sourcePath)
    guard try await destinationMatches(snapshot),
      try await trackedClean(at: source),
      try await ManagedSourceFiles.discover(at: source, excluding: dataRoot).isEmpty else {
      throw AgentFailure(message: "移交两边尚未完成校验，已保留恢复快照。")
    }
    if let stash = snapshot.stashCommit {
      let current = try await LocalWorkspaceService.git(
        ["rev-parse", "--verify", snapshot.protectedReference + "^{commit}"], at: source)
      if current.status == 0 {
        guard current.text.trimmingCharacters(in: .whitespacesAndNewlines) == stash else {
          throw AgentFailure(message: "Git 移交保护引用已改变，未清理快照。")
        }
        _ = try await GitReviewService.checked(
          ["update-ref", "-d", snapshot.protectedReference, stash], at: source)
      }
    }
    try ManagedSourceFiles.removeSnapshotChecked(dataRoot: dataRoot, taskID: snapshot.taskID)
  }

  /// Undo only an unpublished capture. Neither checkout may have been modified by this transfer.
  static func discardUnapplied(_ snapshot: HandoffGitSnapshot, dataRoot: URL) async throws {
    try await validate(snapshot)
    let source = URL(fileURLWithPath: snapshot.sourcePath)
    let target = URL(fileURLWithPath: snapshot.targetPath)
    guard try await trackedMatches(snapshot, at: source),
      try await ManagedSourceFiles.capturedSourceMatches(snapshot.copiedFiles,
        at: source, excluding: dataRoot),
      try await trackedClean(at: target) else {
      throw AgentFailure(message: "检出已发生变化，保留未发布的移交快照。")
    }
    if let stash = snapshot.stashCommit {
      _ = try await GitReviewService.checked(
        ["update-ref", "-d", snapshot.protectedReference, stash], at: source)
    }
    try ManagedSourceFiles.removeSnapshotChecked(dataRoot: dataRoot, taskID: snapshot.taskID)
  }

  private static func validate(_ snapshot: HandoffGitSnapshot) async throws {
    guard UUID(uuidString: snapshot.taskID) != nil,
      validCommitID(snapshot.head),
      snapshot.stashCommit.map(validCommitID) ?? true,
      GitBranchService.canonicalRoot(URL(fileURLWithPath: snapshot.sourcePath)).path == snapshot.sourcePath,
      GitBranchService.canonicalRoot(URL(fileURLWithPath: snapshot.targetPath)).path == snapshot.targetPath else {
      throw AgentFailure(message: "Git 移交记录无效。")
    }
    let source = try await GitBranchService.snapshot(at: URL(fileURLWithPath: snapshot.sourcePath))
    let target = try await GitBranchService.snapshot(at: URL(fileURLWithPath: snapshot.targetPath))
    guard source.canChange, target.canChange,
      try await commonDirectory(at: source.root) == commonDirectory(at: target.root) else {
      throw AgentFailure(message: "移交目录已不属于同一 Git 仓库。")
    }
  }

  private static func trackedMatches(_ snapshot: HandoffGitSnapshot,
    at root: URL) async throws -> Bool {
    let worktree = snapshot.stashCommit ?? snapshot.head
    let index = snapshot.stashCommit.map { $0 + "^2" } ?? snapshot.head
    guard try await quiet(["diff", "--quiet", worktree, "--"], at: root) else { return false }
    return try await quiet(["diff", "--quiet", "--cached", index, "--"], at: root)
  }

  private static func trackedClean(at root: URL) async throws -> Bool {
    guard try await quiet(["diff", "--quiet", "HEAD", "--"], at: root) else { return false }
    return try await quiet(["diff", "--quiet", "--cached", "HEAD", "--"], at: root)
  }

  private static func quiet(_ args: [String], at root: URL) async throws -> Bool {
    let result = try await LocalWorkspaceService.git(args, at: root)
    if result.status == 0 { return true }
    if result.status == 1 { return false }
    throw AgentFailure(message: result.text)
  }

  private static func commit(at root: URL) async throws -> String {
    try await GitReviewService.checked(["rev-parse", "--verify", "HEAD^{commit}"], at: root)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func commonDirectory(at root: URL) async throws -> URL {
    let path = try await GitReviewService.checked(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return GitBranchService.canonicalRoot(URL(fileURLWithPath: path))
  }

  private static func validCommitID(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil
  }
}
