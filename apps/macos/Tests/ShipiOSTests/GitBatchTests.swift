import XCTest

@testable import ShipiOS

final class GitBatchTests: XCTestCase {
  private func repository(initialCommit: Bool = true) async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "ShipiOS Test"], root)
    _ = try await git(["config", "user.email", "qa@example.invalid"], root)
    if initialCommit {
      try write("tracked.txt", "original\n", root)
      try write("deleted.txt", "delete me\n", root)
      _ = try await git(["add", "."], root)
      _ = try await git(["commit", "-qm", "Initial"], root)
    }
    return root
  }
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root)
  }
  private func write(_ path: String, _ text: String, _ root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
  }

  func testStageAndUnstageMixedChangesWithLiteralManifest() async throws {
    let root = try await repository()
    let added = ":(glob)* quote\" 中文\nnew.txt"
    try write("tracked.txt", "edited\n", root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
    try write(added, "new file\n", root)
    let snapshot = try await GitBatchService.capture(scope: .unstaged, at: root)
    XCTAssertEqual(snapshot.selectedFiles.count, 3)
    try await GitBatchService.apply(snapshot)
    let staged = try await GitBatchService.capture(scope: .staged, at: root)
    XCTAssertEqual(staged.selectedFiles.count, 3)
    XCTAssertTrue(staged.files.allSatisfy { !$0.unstaged })
    try await GitBatchService.apply(staged)
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertEqual(try LocalWorkspaceService.read("tracked.txt", root: root), "edited\n")
    XCTAssertEqual(try LocalWorkspaceService.read(added, root: root), "new file\n")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted.txt").path))
  }

  @MainActor func testUnbornBranchUnstagePreservesLaterWorkingEdits() async throws {
    let root = try await repository(initialCommit: false)
    try write("new.txt", "staged\n", root)
    try await GitBatchService.apply(try await GitBatchService.capture(scope: .unstaged, at: root))
    try write("new.txt", "working edit after staging\n", root)
    let staged = try await GitBatchService.capture(scope: .staged, at: root)
    XCTAssertNil(staged.head)
    try await GitBatchService.apply(staged)
    let index = try await git(["ls-files", "-z"], root)
    XCTAssertTrue(index.isEmpty)
    XCTAssertEqual(
      try LocalWorkspaceService.read("new.txt", root: root), "working edit after staging\n")
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.stage("new.txt", undo: false)
    try write("new.txt", "another working edit\n", root)
    await workspace.stage("new.txt", undo: true)
    XCTAssertNil(workspace.error)
    XCTAssertEqual(try LocalWorkspaceService.read("new.txt", root: root), "another working edit\n")
    let afterSingle = try await git(["ls-files", "-z"], root)
    XCTAssertTrue(afterSingle.isEmpty)
  }

  func testBinaryChangesInvalidateSnapshotEvenWhenStatusIsIdentical() async throws {
    let root = try await repository()
    let file = root.appendingPathComponent("binary.dat")
    try Data([0, 1, 2]).write(to: file)
    _ = try await git(["add", "--", "binary.dat"], root)
    _ = try await git(["commit", "-qm", "Binary"], root)
    try Data([0, 3, 4]).write(to: file)
    let snapshot = try await GitBatchService.capture(scope: .unstaged, at: root)
    try Data([0, 5, 6]).write(to: file)
    do {
      try await GitBatchService.apply(snapshot)
      XCTFail("Old binary snapshot must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertEqual(try Data(contentsOf: file), Data([0, 5, 6]))
  }

  func testNewFileAndIndexChangesInvalidateSnapshots() async throws {
    let root = try await repository()
    try write("tracked.txt", "one\n", root)
    let first = try await GitBatchService.capture(scope: .unstaged, at: root)
    try write("another.txt", "new\n", root)
    do {
      try await GitBatchService.apply(first)
      XCTFail("New file invalidates all-files view")
    } catch {}
    try await GitBatchService.apply(try await GitBatchService.capture(scope: .unstaged, at: root))
    let staged = try await GitBatchService.capture(scope: .staged, at: root)
    try write("tracked.txt", "two\n", root)
    _ = try await git(["add", "--", "tracked.txt"], root)
    do {
      try await GitBatchService.apply(staged)
      XCTFail("Changed index must fail")
    } catch {}
    let index = try await git(["show", ":tracked.txt"], root)
    XCTAssertEqual(index, "two\n")
  }

  func testRenameUnstageRestoresBothIndexPaths() async throws {
    let root = try await repository()
    _ = try await git(["mv", "tracked.txt", "renamed.txt"], root)
    let staged = try await GitBatchService.capture(scope: .staged, at: root)
    XCTAssertEqual(Set(staged.paths), ["tracked.txt", "renamed.txt"])
    try await GitBatchService.apply(staged)
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("tracked.txt").path))
  }

  @MainActor func testSymlinkSnapshotDoesNotReadExternalTargetAndRejectsEscapedParents()
    async throws
  {
    let root = try await repository()
    let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data("outside one".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: outside)
    let first = try await GitBatchService.capture(scope: .unstaged, at: root)
    try Data("outside two".utf8).write(to: outside)
    let second = try await GitBatchService.capture(scope: .unstaged, at: root)
    XCTAssertEqual(first.signature, second.signature)
    try await GitBatchService.apply(first)
    let mode = try await git(["ls-files", "--stage", "--", "link"], root)
    XCTAssertTrue(mode.hasPrefix("120000 "))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.stage("link", undo: true)
    XCTAssertNil(workspace.error)
    let unstaged = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(unstaged.isEmpty)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: root.appendingPathComponent("link").path), outside.path)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"),
      withDestinationURL: root.deletingLastPathComponent())
    XCTAssertThrowsError(try GitBatchService.gitPath("escape/other", root: root))
    XCTAssertThrowsError(try GitBatchService.gitPath("../outside", root: root))
    XCTAssertThrowsError(try GitBatchService.gitPath(".git/config", root: root))
  }

  @MainActor func testStoreRejectsWrongProjectAndHistoricalScope() async throws {
    let root = try await repository()
    try write("tracked.txt", "edited\n", root)
    let snapshot = try await GitBatchService.capture(scope: .unstaged, at: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root.appendingPathComponent("other")
    await workspace.stageAll(snapshot)
    workspace.root = root
    workspace.reviewScope = .commit
    await workspace.stageAll(snapshot)
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
    do {
      _ = try await GitBatchService.capture(scope: .branch, at: root)
      XCTFail("History is read-only")
    } catch {}
  }
}
