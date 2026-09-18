import XCTest

@testable import ShipiOS

final class GitDiscardTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func repository() async throws -> URL {
    let root = try directory()
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "ShipiOS Test"], root)
    _ = try await git(["config", "user.email", "qa@example.invalid"], root)
    try write("a.txt", "original a\n", root)
    try write("b.txt", "original b\n", root)
    try write(".gitignore", "ignored.txt\n", root)
    _ = try await git(["add", "."], root)
    _ = try await git(["commit", "-qm", "Initial"], root)
    return root
  }
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root)
  }
  private func write(_ path: String, _ text: String, _ root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
  }
  private func plan(_ root: URL, path: String? = nil) async throws -> GitDiscardPlan {
    try await GitDiscardService.prepare(
      GitBatchService.capture(scope: .unstaged, at: root), selectedPath: path)
  }
  private func move(_ file: URL, to recovery: URL) throws {
    try FileManager.default.moveItem(
      at: file, to: recovery.appendingPathComponent(file.lastPathComponent))
  }

  func testDiscardOneFilePreservesStagedVersionAndOtherWorkingChanges() async throws {
    let root = try await repository()
    try write("a.txt", "staged a\n", root)
    _ = try await git(["add", "a.txt"], root)
    try write("a.txt", "working a\n", root)
    try write("b.txt", "working b\n", root)
    let request = try await plan(root, path: "a.txt")
    XCTAssertEqual(request.restorePaths, ["a.txt"])
    XCTAssertTrue(request.trashPaths.isEmpty)
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "working a\n")
    try await GitDiscardService.execute(
      request, trash: { _ in XCTFail("Tracked file must not be trashed") })
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "staged a\n")
    XCTAssertEqual(try LocalWorkspaceService.read("b.txt", root: root), "working b\n")
    let index = try await git(["show", ":a.txt"], root)
    XCTAssertEqual(index, "staged a\n")
  }

  func testDiscardAllRestoresDeletedFilesAndMovesUntrackedContent() async throws {
    let root = try await repository()
    let recovery = try directory()
    let path = ":(glob)* 中文\nnew.bin"
    try write("a.txt", "changed\n", root)
    try write("ignored.txt", "keep ignored\n", root)
    try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
    try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent(path))
    let outside = recovery.appendingPathComponent("outside.txt")
    try Data("external".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: outside)
    let request = try await plan(root)
    XCTAssertEqual(Set(request.restorePaths), ["a.txt", "b.txt"])
    XCTAssertEqual(Set(request.trashPaths), [path, "link"])
    try await GitDiscardService.execute(request, trash: { try self.move($0, to: recovery) })
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "original a\n")
    XCTAssertEqual(try LocalWorkspaceService.read("b.txt", root: root), "original b\n")
    XCTAssertEqual(try LocalWorkspaceService.read("ignored.txt", root: root), "keep ignored\n")
    XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent(path)), Data([0, 1, 2, 3]))
    XCTAssertEqual(try String(contentsOf: outside), "external")
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: recovery.appendingPathComponent("link").path), outside.path)
    let status = try await git(["status", "--porcelain"], root)
    XCTAssertTrue(status.isEmpty)
  }

  func testIntentToAddDiscardRemovesEmptyIndexMarkerAndPreservesRecoveryCopy() async throws {
    let root = try await repository()
    let recovery = try directory()
    try write("intent.txt", "new content\n", root)
    _ = try await git(["add", "-N", "--", "intent.txt"], root)
    let request = try await plan(root)
    XCTAssertEqual(request.intentPaths, ["intent.txt"])
    XCTAssertTrue(request.restorePaths.isEmpty)
    try await GitDiscardService.execute(request, trash: { try self.move($0, to: recovery) })
    let entry = try await git(["ls-files", "--", "intent.txt"], root)
    XCTAssertTrue(entry.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: recovery.appendingPathComponent("intent.txt")), "new content\n")
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
  }

  func testChangedAfterConfirmationPreventsRestoreAndTrash() async throws {
    let root = try await repository()
    try write("a.txt", "first\n", root)
    try write("new.txt", "new\n", root)
    let request = try await plan(root)
    try write("a.txt", "external edit\n", root)
    do {
      try await GitDiscardService.execute(
        request, trash: { _ in XCTFail("Stale plan must not trash anything") })
      XCTFail("Must reject stale plan")
    } catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "external edit\n")
    XCTAssertEqual(try LocalWorkspaceService.read("new.txt", root: root), "new\n")
  }

  func testPartialTrashFailureIsReportedAndTrackedFilesRemainUntouched() async throws {
    let root = try await repository()
    let recovery = try directory()
    try write("a.txt", "changed\n", root)
    try write("new1.txt", "first\n", root)
    try write("new2.txt", "second\n", root)
    let request = try await plan(root)
    do {
      try await GitDiscardService.execute(
        request,
        trash: { file in
          if file.lastPathComponent == "new2.txt" {
            throw AgentFailure(message: "simulated trash failure")
          }
          try self.move(file, to: recovery)
        })
      XCTFail("Must report failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("部分操作"))
      XCTAssertTrue(error.localizedDescription.contains("1 项"))
    }
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "changed\n")
    XCTAssertEqual(try LocalWorkspaceService.read("new2.txt", root: root), "second\n")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: recovery.appendingPathComponent("new1.txt").path))
  }

  func testStagedRenameIsPreservedWhenDiscardingLaterWorkingEdit() async throws {
    let root = try await repository()
    _ = try await git(["mv", "a.txt", "renamed.txt"], root)
    try write("renamed.txt", "working change\n", root)
    let request = try await plan(root)
    XCTAssertEqual(request.restorePaths, ["renamed.txt"])
    try await GitDiscardService.execute(
      request, trash: { _ in XCTFail("Staged rename must not be trashed") })
    XCTAssertEqual(try LocalWorkspaceService.read("renamed.txt", root: root), "original a\n")
    let status = GitFile.parse(try await git(["status", "--porcelain=v1", "-z"], root))
    XCTAssertTrue(status.first?.indexRename == true)
    XCTAssertFalse(status.first?.unstaged == true)
  }

  func testNestedRepositoryAndConflictAreRejectedBeforeChanges() async throws {
    let root = try await repository()
    let nested = try await repository()
    let destination = root.appendingPathComponent("nested")
    try FileManager.default.moveItem(at: nested, to: destination)
    do {
      _ = try await plan(root)
      XCTFail("Nested repository requires its own scope")
    } catch { XCTAssertTrue(error.localizedDescription.contains("子仓库")) }
    try FileManager.default.moveItem(at: destination, to: nested)
    _ = try await git(["checkout", "-qb", "other"], root)
    try write("a.txt", "other\n", root)
    _ = try await git(["commit", "-qam", "Other"], root)
    _ = try await git(["checkout", "-q", "main"], root)
    try write("a.txt", "main\n", root)
    _ = try await git(["commit", "-qam", "Main"], root)
    let merge = try await LocalWorkspaceService.git(["merge", "--no-edit", "other"], at: root)
    XCTAssertNotEqual(merge.status, 0)
    let before = try LocalWorkspaceService.read("a.txt", root: root)
    do {
      _ = try await plan(root)
      XCTFail("Conflict requires explicit resolution")
    } catch { XCTAssertTrue(error.localizedDescription.contains("冲突")) }
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), before)
  }

  @MainActor func testPreparingAndCancellingDoesNotModifyFilesOrIndex() async throws {
    let root = try await repository()
    try write("a.txt", "working\n", root)
    let snapshot = try await GitBatchService.capture(scope: .unstaged, at: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.prepareDiscard(snapshot, path: "a.txt")
    XCTAssertNotNil(workspace.discardPlan)
    XCTAssertFalse(workspace.gitBusy)
    workspace.discardPlan = nil
    XCTAssertEqual(try LocalWorkspaceService.read("a.txt", root: root), "working\n")
    let cached = try await git(["diff", "--cached", "--name-only"], root)
    XCTAssertTrue(cached.isEmpty)
  }
}
