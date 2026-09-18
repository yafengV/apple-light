import XCTest

@testable import ShipiOS

final class GitHunkTests: XCTestCase {
  func testAddedFileUnstagePreservesWorkingCopy() async throws {
    let root = try await repository()
    let added = "new file.txt"
    try write("new content\n", root, path: added)
    _ = try await git(["add", "--", added], root)
    let patch = try await snapshot(.staged, root, path: added)
    XCTAssertEqual(patch.hunks.count, 1)
    try await apply(.unstage, patch, root, path: added)
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertEqual(try LocalWorkspaceService.read(added, root: root), "new content\n")
  }

  @MainActor func testHistoricalScopeCannotRunHunkMutation() async throws {
    let root = try await repository()
    try write(changed, root)
    let patch = try await snapshot(.unstaged, root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.reviewScope = .commit
    let file = GitFile(path: path, staged: false, unstaged: true, untracked: false)
    await workspace.applyHunk(
      .revert, file: file, hunk: patch.hunks[0], snapshot: patch, project: root)
    await workspace.applyHunk(
      .stage, file: file, hunk: patch.hunks[0], snapshot: patch, project: root)
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), changed)
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertFalse(workspace.gitBusy)
  }
  private let path = ":(glob)* quoted\" 中文\nfile.txt"
  private var baseline: String { (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n" }
  private var changed: String {
    baseline.replacingOccurrences(of: "line 3\n", with: "first change\n").replacingOccurrences(
      of: "line 50\n", with: "second change\n")
  }

  private func repository() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "ShipiOS Test"], root)
    _ = try await git(["config", "user.email", "qa@example.invalid"], root)
    try write(baseline, root)
    _ = try await git(["add", "--", path], root)
    _ = try await git(["commit", "-qm", "Initial"], root)
    return root
  }
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root)
  }
  private func write(_ text: String, _ root: URL, path: String? = nil) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path ?? self.path))
  }
  private func snapshot(_ scope: GitReviewScope, _ root: URL, path: String? = nil) async throws
    -> ReviewDiff
  {
    let status = try await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root)
    let file = try XCTUnwrap(GitFile.parse(status).first { $0.path == (path ?? self.path) })
    let args = try await GitReviewService.arguments(scope: scope, selection: "", at: root)
    return try await GitReviewService.fileDiff(file, scope: scope, arguments: args, at: root)
  }
  private func apply(
    _ action: GitHunkAction, _ patch: ReviewDiff, _ root: URL, index: Int = 0, path: String? = nil
  ) async throws {
    try await GitHunkService.apply(
      action, path: path ?? self.path,
      hunkID: patch.hunks[index].id, snapshot: patch, at: root)
  }

  func testStageOneHunkAndUnstageWithoutChangingWorkingFile() async throws {
    let root = try await repository()
    try write(changed, root)
    let patch = try await snapshot(.unstaged, root)
    XCTAssertEqual(patch.hunks.count, 2)
    try await apply(.stage, patch, root)
    let index = try await git(["show", ":" + path], root)
    XCTAssertTrue(index.contains("first change"))
    XCTAssertFalse(index.contains("second change"))
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), changed)
    let staged = try await snapshot(.staged, root)
    try await apply(.unstage, staged, root)
    let restored = try await git(["show", ":" + path], root)
    XCTAssertEqual(restored, baseline)
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), changed)
  }

  func testRevertUnstagedHunkPreservesStagedAndOtherContent() async throws {
    let root = try await repository()
    try write(changed, root)
    try await apply(.stage, try await snapshot(.unstaged, root), root)
    let indexBefore = try await git(["show", ":" + path], root)
    let remaining = try await snapshot(.unstaged, root)
    XCTAssertEqual(remaining.hunks.count, 1)
    try await apply(.revert, remaining, root)
    let indexAfter = try await git(["show", ":" + path], root)
    XCTAssertEqual(indexBefore, indexAfter)
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), indexBefore)
    XCTAssertTrue(indexAfter.contains("first change"))
  }

  func testStaleSnapshotDoesNotMutateIndexOrWorktree() async throws {
    let root = try await repository()
    try write(changed, root)
    let old = try await snapshot(.unstaged, root)
    let newer = changed.replacingOccurrences(of: "line 30", with: "external edit")
    try write(newer, root)
    for action in [GitHunkAction.stage, .revert] {
      do {
        try await apply(action, old, root)
        XCTFail("Stale snapshot should fail")
      } catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    }
    let index = try await git(["show", ":" + path], root)
    XCTAssertEqual(index, baseline)
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), newer)
  }

  func testNoFinalNewlineSurvivesHunkStageAndUnstage() async throws {
    let root = try await repository()
    try write(String(baseline.dropLast()), root)
    _ = try await git(["add", "--", path], root)
    _ = try await git(["commit", "-qm", "No newline"], root)
    let change = String(changed.dropLast()).replacingOccurrences(of: "line 60", with: "last line")
    try write(change, root)
    let patch = try await snapshot(.unstaged, root)
    XCTAssertGreaterThanOrEqual(patch.hunks.count, 2)
    try await apply(.stage, patch, root, index: patch.hunks.count - 1)
    let index = try await git(["show", ":" + path], root)
    XCTAssertFalse(index.hasSuffix("\n"))
    XCTAssertTrue(index.hasSuffix("last line"))
    try await apply(.unstage, try await snapshot(.staged, root), root)
    let restored = try await git(["show", ":" + path], root)
    XCTAssertEqual(restored, String(baseline.dropLast()))
  }

  func testUnstageHunkPreservesRenameAndStagePreservesExecutableMode() async throws {
    let root = try await repository()
    let renamed = "renamed.txt"
    _ = try await git(["mv", "--", path, renamed], root)
    try write(changed, root, path: renamed)
    _ = try await git(["add", "--", renamed], root)
    try await apply(.unstage, try await snapshot(.staged, root, path: renamed), root, path: renamed)
    let index = try await git(["show", ":" + renamed], root)
    XCTAssertFalse(index.contains("first change"))
    XCTAssertTrue(index.contains("second change"))
    let status = GitFile.parse(try await git(["status", "--porcelain=v1", "-z"], root))
    XCTAssertEqual(status.first?.originalPath, path)
    XCTAssertTrue(status.first?.indexRename == true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(renamed).path)
    try await apply(.stage, try await snapshot(.unstaged, root, path: renamed), root, path: renamed)
    let mode = try await git(["ls-files", "--stage", "--", renamed], root)
    XCTAssertTrue(mode.hasPrefix("100644 "))
    XCTAssertEqual(try LocalWorkspaceService.read(renamed, root: root), changed)
  }

  func testDeletedFileHunkCanStageAndUnstage() async throws {
    let root = try await repository()
    try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    try await apply(.stage, try await snapshot(.unstaged, root), root)
    let files = try await git(["ls-files", "-z"], root)
    XCTAssertTrue(files.isEmpty)
    try await apply(.unstage, try await snapshot(.staged, root), root)
    let index = try await git(["show", ":" + path], root)
    XCTAssertEqual(index, baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
  }

  func testInvalidHunkAndTraversalAreRejected() async throws {
    let root = try await repository()
    try write(changed, root)
    let patch = try await snapshot(.unstaged, root)
    do {
      try await GitHunkService.apply(.stage, path: path, hunkID: -1, snapshot: patch, at: root)
      XCTFail("Unknown hunk should fail")
    } catch {}
    do {
      try await GitHunkService.apply(
        .revert, path: "../outside", hunkID: patch.hunks[0].id, snapshot: patch, at: root)
      XCTFail("Outside path should fail")
    } catch {}
    let index = try await git(["show", ":" + path], root)
    XCTAssertEqual(index, baseline)
    XCTAssertEqual(try LocalWorkspaceService.read(path, root: root), changed)
    XCTAssertFalse(ReviewDiff("Binary files a/file and b/file differ").supportsHunkActions)
    XCTAssertFalse(ReviewDiff.untracked("hello").supportsHunkActions)
  }
}
