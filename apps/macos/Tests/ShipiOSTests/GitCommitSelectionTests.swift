import XCTest
@testable import ShipiOS

final class GitCommitSelectionTests: XCTestCase {
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func repository(commit: Bool = true) async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "Test"], root)
    _ = try await git(["config", "user.email", "test@example.invalid"], root)
    try write("file.txt", "initial", at: root)
    try write(".gitignore", "ignored.txt\n", at: root)
    _ = try await git(["add", "--all"], root)
    if commit { _ = try await git(["commit", "-qm", "initial"], root) }
    return root
  }
  private func write(_ path: String, _ text: String, at root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
  }
  private func mixedChanges(_ root: URL) async throws {
    try write("file.txt", "staged content", at: root)
    _ = try await git(["add", "file.txt"], root)
    try write("file.txt", "working content", at: root)
    try write("new file.txt", "untracked content", at: root)
    try write("ignored.txt", "must stay private", at: root)
  }
  @MainActor private func workspace(_ root: URL) async -> DeveloperWorkspace {
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    workspace.commitMessage = "Selected changes"
    return workspace
  }
  private func index(_ root: URL) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(".git/index"))
  }

  func testFullGenerationDiffIncludesWorkingAndUntrackedWithoutChangingIndex() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let before = try index(root)
    let full = try await GitCommitContext.capture(at: root, includeUnstaged: true)
    XCTAssertTrue(full.diff.contains("working content"))
    XCTAssertTrue(full.diff.contains("untracked content"))
    XCTAssertFalse(full.diff.contains("staged content"))
    XCTAssertFalse(full.diff.contains("must stay private"))
    XCTAssertEqual(try index(root), before)
    let staged = try await GitCommitContext.capture(at: root)
    XCTAssertTrue(staged.diff.contains("staged content"))
    XCTAssertFalse(staged.diff.contains("untracked content"))
  }

  @MainActor func testNewBranchCommitsAllSelectedContentWithoutAdvancingOriginalBranch() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let original = try await git(["rev-parse", "main"], root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    let workspace = await workspace(root)
    let success = await store.performGitAction(.commit, in: workspace,
      includeUnstaged: true, newBranch: "codex/selected")
    XCTAssertTrue(success, workspace.error ?? "")
    let branch = try await git(["branch", "--show-current"], root)
    XCTAssertEqual(branch, "codex/selected")
    let oldHead = try await git(["rev-parse", "main"], root)
    XCTAssertEqual(oldHead, original)
    let contents = try await git(["show", "HEAD:file.txt"], root)
    XCTAssertEqual(contents, "working content")
    let untracked = try await git(["show", "HEAD:new file.txt"], root)
    XCTAssertEqual(untracked, "untracked content")
    let status = try await git(["status", "--porcelain"], root)
    XCTAssertTrue(status.isEmpty)
    XCTAssertEqual(workspace.commitMessage, "")
  }

  @MainActor func testStagedOnlyCommitLeavesWorktreeAndUntrackedContent() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    let workspace = await workspace(root)
    let success = await store.performGitAction(.commit, in: workspace)
    XCTAssertTrue(success, workspace.error ?? "")
    let committed = try await git(["show", "HEAD:file.txt"], root)
    XCTAssertEqual(committed, "staged content")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "working content")
    let status = try await git(["status", "--porcelain"], root)
    XCTAssertTrue(status.contains(" M file.txt"))
    XCTAssertTrue(status.contains("new file.txt"))
  }

  @MainActor func testInvalidAndExistingBranchNamesPreserveIndexDraftAndHead() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    let workspace = await workspace(root)
    let head = try await git(["rev-parse", "HEAD"], root)
    let staged = try await git(["diff", "--cached"], root)
    for name in ["main", "../invalid", "-bad", "@{-1}"] {
      let success = await store.performGitAction(.commit, in: workspace, includeUnstaged: true, newBranch: name)
      XCTAssertFalse(success)
      XCTAssertNotNil(workspace.error)
      XCTAssertEqual(workspace.commitMessage, "Selected changes")
      let current = try await git(["rev-parse", "HEAD"], root)
      let currentIndex = try await git(["diff", "--cached"], root)
      XCTAssertEqual(current, head)
      XCTAssertEqual(currentIndex, staged)
    }
  }

  func testStaleSelectionRejectsWorktreeChangesBeforeCreatingBranch() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let selection = try await GitCommitSelection.capture(at: root, includeUnstaged: true, newBranch: "codex/stale")
    try write("file.txt", "edited while generating", at: root)
    do { try await selection.apply(); XCTFail("stale selection must fail") }
    catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    let branch = try await git(["branch", "--show-current"], root)
    XCTAssertEqual(branch, "main")
    let missing = try await LocalWorkspaceService.git(["show-ref", "--verify", "refs/heads/codex/stale"], at: root)
    XCTAssertNotEqual(missing.status, 0)
  }

  @MainActor func testCommitHookFailureKeepsNewBranchAndDraftForRetry() async throws {
    let root = try await repository()
    try await mixedChanges(root)
    let hook = root.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    let workspace = await workspace(root)
    let failed = await store.performGitAction(.commit, in: workspace,
      includeUnstaged: true, newBranch: "codex/retry")
    XCTAssertFalse(failed)
    XCTAssertEqual(workspace.gitBranch, "codex/retry")
    XCTAssertEqual(workspace.commitMessage, "Selected changes")
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertFalse(workspace.gitActionRunning)
    try FileManager.default.removeItem(at: hook)
    let retried = await store.performGitAction(.commit, in: workspace)
    XCTAssertTrue(retried, workspace.error ?? "")
    let count = try await git(["rev-list", "--count", "HEAD"], root)
    XCTAssertEqual(count, "2")
  }

  @MainActor func testNewBranchOnUnbornRepositoryCommitsInitialFiles() async throws {
    let root = try await repository(commit: false)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    let workspace = await workspace(root)
    let result = await store.performGitAction(.commit, in: workspace, newBranch: "codex/first")
    XCTAssertTrue(result, workspace.error ?? "")
    XCTAssertEqual(workspace.gitBranch, "codex/first")
    let count = try await git(["rev-list", "--count", "HEAD"], root)
    XCTAssertEqual(count, "1")
  }

  @MainActor func testSelectionPreferenceMigratesAndPersists() throws {
    let preferences = try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8))
    XCTAssertTrue(preferences.includeUnstagedInCommit)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var changed = preferences
    changed.includeUnstagedInCommit = false
    XCTAssertTrue(store.saveGitPreferences(changed))
    let reloaded = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(reloaded.gitPreferences.includeUnstagedInCommit)
  }

  func testFullDiffPreservesSparseCheckoutAndSplitIndex() async throws {
    let root = try await repository()
    for folder in ["included", "excluded"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
      try write(folder + "/file.txt", "original", at: root)
    }
    _ = try await git(["add", "--all"], root)
    _ = try await git(["commit", "-qm", "directories"], root)
    _ = try await git(["sparse-checkout", "init", "--cone", "--no-sparse-index"], root)
    _ = try await git(["sparse-checkout", "set", "included"], root)
    _ = try await git(["update-index", "--split-index"], root)
    try write("included/file.txt", "changed", at: root)
    let before = try index(root)
    let context = try await GitCommitContext.capture(at: root, includeUnstaged: true)
    XCTAssertTrue(context.diff.contains("included/file.txt"))
    XCTAssertFalse(context.diff.contains("excluded/file.txt"))
    XCTAssertEqual(try index(root), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("excluded/file.txt").path))
  }
}
