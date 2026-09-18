import XCTest

@testable import ShipiOS

final class GitReviewTests: XCTestCase {
  @MainActor func testStagedRenameDiffAndUnstageOperateOnBothPaths() async throws {
    let root = try await repository()
    let old = "old file.swift"
    let new = "new file.swift"
    try write(old, "one\ntwo\nthree\nfour\nfive\n", root)
    _ = try await commit("Initial", root)
    _ = try await git(["mv", "--", old, new], root)
    try write(new, "one\ntwo\nchanged\nfour\nfive\n", root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    let file = try XCTUnwrap(workspace.gitFiles.first { $0.path == new })
    XCTAssertEqual(file.originalPath, old)
    XCTAssertTrue(file.indexRename)
    XCTAssertEqual(file.comparisonPaths(scope: .staged), [old, new])
    XCTAssertEqual(file.comparisonPaths(scope: .unstaged), [new])
    await workspace.stage(new, undo: false)
    XCTAssertNil(workspace.error)
    let args = try await GitReviewService.arguments(scope: .staged, selection: "", at: root)
    let patch = try await GitReviewService.fileDiff(file, scope: .staged, arguments: args, at: root)
    XCTAssertTrue(patch.lines.contains { $0.text.hasPrefix("rename from ") })
    XCTAssertEqual(patch.additions, 1)
    XCTAssertEqual(patch.deletions, 1)
    await workspace.stage(new, undo: true)
    XCTAssertNil(workspace.error)
    let staged = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(staged.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(old).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(new).path))
  }

  func testHistoricalRenameKeepsBothPathsAndHandlesNulRecords() async throws {
    let root = try await repository()
    let old = ":(glob)* old\n.swift"
    let new = "new\t.swift"
    try write(old, "one\ntwo\nthree\nfour\nfive\n", root)
    _ = try await commit("Initial", root)
    _ = try await git(["mv", "--", old, new], root)
    _ = try await commit("Rename", root)
    let args = try await GitReviewService.arguments(scope: .commit, selection: "HEAD", at: root)
    let files = try await GitReviewService.files(arguments: args, at: root)
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files.first?.originalPath, old)
    XCTAssertEqual(files.first?.path, new)
    let patch = try await GitReviewService.fileDiff(
      try XCTUnwrap(files.first), scope: .commit, arguments: args, at: root)
    XCTAssertEqual(patch.additions, 0)
    XCTAssertEqual(patch.deletions, 0)
    XCTAssertTrue(patch.lines.contains { $0.text.hasPrefix("rename from ") })
    let parsed = GitFile.parseNameStatus("R100\0old\0new\0M\0other\0D\0gone\0")
    XCTAssertEqual(parsed.map(\.path), ["new", "other", "gone"])
    XCTAssertEqual(parsed.first?.originalPath, "old")
  }
  func testFilePreviewHandlesUntrackedAndLiteralPaths() async throws {
    let root = try await repository()
    let path = ":(glob)* file.swift"
    try write(path, "old\n", root)
    _ = try await commit("Initial", root)
    try write(path, "new\n", root)
    try write("other.swift", "new file\n", root)
    let args = try await GitReviewService.arguments(scope: .unstaged, selection: "", at: root)
    let tracked = try await GitReviewService.fileDiff(
      GitFile(path: path, staged: false, unstaged: true, untracked: false),
      scope: .unstaged, arguments: args, at: root)
    XCTAssertEqual(tracked.additions, 1)
    XCTAssertEqual(tracked.deletions, 1)
    XCTAssertFalse(tracked.lines.contains { $0.text.contains("new file") })
    let untracked = try await GitReviewService.fileDiff(
      GitFile(path: "other.swift", staged: false, unstaged: true, untracked: true),
      scope: .unstaged, arguments: args, at: root)
    XCTAssertEqual(untracked.lines.filter(\.canComment).map(\.newLine), [1])
    XCTAssertEqual(untracked.additions, 1)
  }
  private func repository() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "ShipiOS Test"], root)
    _ = try await git(["config", "user.email", "qa@example.invalid"], root)
    return root
  }
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root)
  }
  private func write(_ path: String, _ value: String, _ root: URL) throws {
    try Data(value.utf8).write(to: root.appendingPathComponent(path))
  }
  private func commit(_ message: String, _ root: URL) async throws -> String {
    _ = try await git(["add", "--all"], root)
    _ = try await git(["commit", "-q", "-m", message], root)
    return try await git(["rev-parse", "HEAD"], root).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  func testRootCommitAndLiteralDeletedFile() async throws {
    let root = try await repository()
    let path = ":(glob)* unusual\nname.txt"
    try write(path, "first\n", root)
    let first = try await commit("Initial", root)
    let initial = try await GitReviewService.arguments(scope: .commit, selection: first, at: root)
    let initialFiles = try await GitReviewService.files(arguments: initial, at: root)
    XCTAssertEqual(initialFiles.map(\.path), [path])
    let diff = try await git(initial + ["--", path], root)
    XCTAssertTrue(diff.contains("+first"))
    try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    let second = try await commit("Delete", root)
    let deleted = try await GitReviewService.arguments(scope: .commit, selection: second, at: root)
    let deletedFiles = try await GitReviewService.files(arguments: deleted, at: root)
    XCTAssertEqual(deletedFiles.map(\.path), [path])
    let removed = try await git(deleted + ["--", path], root)
    XCTAssertTrue(removed.contains("-first"))
    let choices = try await GitReviewService.commits(at: root)
    XCTAssertEqual(choices.map(\.id), [second, first])
  }

  func testBranchUsesMergeBaseAndExcludesDirtyWorktree() async throws {
    let root = try await repository()
    try write("shared", "base\n", root)
    _ = try await commit("Initial", root)
    _ = try await git(["checkout", "-q", "-b", "feature"], root)
    try write("feature", "feature\n", root)
    _ = try await commit("Feature", root)
    _ = try await git(["checkout", "-q", "main"], root)
    try write("main-only", "main\n", root)
    _ = try await commit("Base advanced", root)
    _ = try await git(["checkout", "-q", "feature"], root)
    try write("shared", "dirty\n", root)
    let args = try await GitReviewService.arguments(
      scope: .branch, selection: "refs/heads/main", at: root)
    let files = try await GitReviewService.files(arguments: args, at: root)
    XCTAssertEqual(files.map(\.path), ["feature"])
    let choices = try await GitReviewService.branches(at: root)
    XCTAssertEqual(Set(choices.map(\.id)), ["refs/heads/main", "refs/heads/feature"])
    let diff = try await git(args + ["--", "."], root)
    XCTAssertFalse(diff.contains("dirty"))
    XCTAssertFalse(diff.contains("main-only"))
  }

  func testMergeCommitComparesFirstParent() async throws {
    let root = try await repository()
    try write("shared", "base\n", root)
    _ = try await commit("Initial", root)
    _ = try await git(["checkout", "-q", "-b", "feature"], root)
    try write("feature", "feature\n", root)
    _ = try await commit("Feature", root)
    _ = try await git(["checkout", "-q", "main"], root)
    _ = try await git(["merge", "--no-ff", "-m", "Merge", "feature"], root)
    let args = try await GitReviewService.arguments(scope: .commit, selection: "HEAD", at: root)
    let files = try await GitReviewService.files(arguments: args, at: root)
    XCTAssertEqual(files.map(\.path), ["feature"])
  }

  func testModelReviewUncommittedSnapshotIncludesStagedUnstagedAndUntrackedChanges() async throws {
    let root = try await repository()
    try write("staged.swift", "let staged = 0\n", root)
    try write("unstaged.swift", "let unstaged = 0\n", root)
    _ = try await commit("Initial", root)
    try write("staged.swift", "let staged = 1\n", root)
    _ = try await git(["add", "--", "staged.swift"], root)
    try write("unstaged.swift", "let unstaged = 2\n", root)
    try write("new file.swift", "let untracked = true\n", root)

    let snapshot = try await GitReviewService.modelReviewSnapshot(
      scope: .uncommitted, at: root)

    XCTAssertTrue(snapshot.diff.contains("+let staged = 1"))
    XCTAssertTrue(snapshot.diff.contains("+let unstaged = 2"))
    XCTAssertTrue(snapshot.diff.contains("new file.swift"))
    XCTAssertTrue(snapshot.diff.contains("+let untracked = true"))
    XCTAssertEqual(snapshot.requestTitle, "审查未提交的更改")
  }

  func testModelReviewBranchUsesMergeBaseAndRejectsEmptyOrOversizedDiffs() async throws {
    let root = try await repository()
    try write("base.swift", "let base = true\n", root)
    _ = try await commit("Initial", root)
    _ = try await git(["checkout", "-q", "-b", "feature"], root)
    try write("feature.swift", "let feature = true\n", root)
    _ = try await commit("Feature", root)

    let snapshot = try await GitReviewService.modelReviewSnapshot(
      scope: .branch("refs/heads/main"), at: root)
    XCTAssertTrue(snapshot.diff.contains("feature.swift"))
    XCTAssertFalse(snapshot.diff.contains("base.swift"))

    do {
      _ = try await GitReviewService.modelReviewSnapshot(
        scope: .branch("refs/heads/feature"), at: root)
      XCTFail("Expected an empty review error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("没有可审查"))
    }

    try write("large.txt", String(repeating: "0123456789abcdef\n", count: 40_000), root)
    do {
      _ = try await GitReviewService.modelReviewSnapshot(scope: .uncommitted, at: root)
      XCTFail("Expected the size boundary to reject the review")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("512 KiB"))
    }
  }

  @MainActor func testDetachedReviewSetupFailureRemovesPendingTaskAndPreservesPicker() async throws {
    let root = try await repository()
    try write("file.swift", "let value = 1\n", root)
    _ = try await commit("Initial", root)
    try write("file.swift", "let value = 2\n", root)
    let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let store = WorkspaceStore(dataRoot: dataRoot)
    store.project = root
    store.workspace.setProject(root)
    store.library.gitPreferences.reviewDelivery = .detached
    store.showingReviewMode = true
    store.reviewModeProject = root.path

    await store.startCodeReview(.uncommitted)

    XCTAssertTrue(store.showingReviewMode)
    XCTAssertFalse(store.reviewModeStarting)
    XCTAssertNotNil(store.reviewModeError)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertFalse(store.library.tasks.contains { $0.isPopoutDraft && $0.runIDs.isEmpty })
  }

  @MainActor func testEmptyRepositoryMissingReferenceAndReadOnlyScope() async throws {
    let root = try await repository()
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertTrue(workspace.reviewCommits.isEmpty)
    XCTAssertNil(workspace.error)
    try write("file", "initial\n", root)
    let first = try await commit("Initial", root)
    await workspace.refreshGit()
    workspace.reviewScope = .commit
    workspace.reviewCommit = first
    await workspace.loadDiff()
    XCTAssertEqual(workspace.visibleChanges.map(\.path), ["file"])
    XCTAssertTrue(workspace.diff.contains("+initial"))
    try write("file", "dirty\n", root)
    await workspace.stage("file", undo: false)
    let staged = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(staged.isEmpty)
    workspace.reviewCommit = "--bad-option"
    await workspace.loadDiff()
    XCTAssertNotNil(workspace.error)
    XCTAssertTrue(workspace.diff.isEmpty)
    XCTAssertTrue(workspace.visibleChanges.isEmpty)
    workspace.reviewScope = .unstaged
    await workspace.refreshGit()
    XCTAssertNil(workspace.error)
    XCTAssertTrue(workspace.diff.contains("+dirty"))
  }

  @MainActor func testProjectSwitchDiscardsInFlightDiff() async throws {
    let root = try await repository()
    try write("file", "old project\n", root)
    let first = try await commit("Initial", root)
    let other = try await repository()
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.reviewScope = .commit
    workspace.reviewCommit = first
    let request = Task { await workspace.loadDiff() }
    await Task.yield()
    workspace.setProject(other)
    await request.value
    await workspace.refreshGit()
    XCTAssertEqual(workspace.reviewScope, .unstaged)
    XCTAssertTrue(workspace.reviewCommits.isEmpty)
    XCTAssertTrue(workspace.diff.isEmpty)
    XCTAssertNil(workspace.error)
  }
}
