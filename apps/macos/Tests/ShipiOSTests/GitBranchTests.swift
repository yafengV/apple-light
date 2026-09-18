import XCTest

@testable import ShipiOS

final class GitBranchTests: XCTestCase {
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root)
  }
  private func write(_ path: String, _ value: String, _ root: URL) throws {
    try Data(value.utf8).write(to: root.appendingPathComponent(path))
  }
  private func commit(_ root: URL) async throws {
    _ = try await git(["add", "--all"], root)
    _ = try await git(["commit", "-qm", "Fixture"], root)
  }
  private func repository() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("branch test \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], root)
    _ = try await git(["config", "user.name", "ShipiOS Test"], root)
    _ = try await git(["config", "user.email", "test@example.invalid"], root)
    try write("file", "main\n", root)
    try write("other", "unchanged\n", root)
    try await commit(root)
    return root
  }
  private func choice(_ name: String, _ snapshot: GitBranchSnapshot) throws -> GitBranchChoice {
    try XCTUnwrap(snapshot.branches.first { $0.name == name })
  }
  private func rejected(_ change: GitBranchChange, _ snapshot: GitBranchSnapshot) async {
    do {
      try await GitBranchService.apply(change, snapshot: snapshot)
      XCTFail("Expected Git to refuse the operation")
    } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
  }

  func testSwitchCarriesCompatibleChangesButRejectsConflicts() async throws {
    let root = try await repository()
    _ = try await git(["switch", "-c", "feature"], root)
    try write("file", "feature\n", root)
    try await commit(root)
    _ = try await git(["switch", "main"], root)
    try write("other", "keep my change\n", root)
    let before = try await GitBranchService.snapshot(at: root)
    XCTAssertEqual(before.changedFiles, 1)
    try await GitBranchService.apply(.switchTo(try choice("feature", before)), snapshot: before)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "feature\n")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other")), "keep my change\n")
    try write("file", "uncommitted work\n", root)
    let after = try await GitBranchService.snapshot(at: root)
    await rejected(.switchTo(try choice("main", after)), after)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "uncommitted work\n")
    let final = try await GitBranchService.snapshot(at: root)
    XCTAssertEqual(final.currentName, "feature")
  }

  func testIgnoredFileCollisionIsNeverOverwritten() async throws {
    let root = try await repository()
    try write(".gitignore", "private\n", root)
    try await commit(root)
    _ = try await git(["switch", "-c", "feature"], root)
    try write("private", "tracked on feature\n", root)
    _ = try await git(["add", "-f", "private"], root)
    _ = try await git(["commit", "-qm", "Add file"], root)
    _ = try await git(["switch", "main"], root)
    try write("private", "local ignored content\n", root)
    let snapshot = try await GitBranchService.snapshot(at: root)
    await rejected(.switchTo(try choice("feature", snapshot)), snapshot)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("private")), "local ignored content\n")
  }

  func testDetachedBranchCreationAndInvalidNames() async throws {
    let root = try await repository()
    _ = try await git(["switch", "--detach"], root)
    let detached = try await GitBranchService.snapshot(at: root)
    XCTAssertNil(detached.currentReference)
    for name in ["", "bad name", "-bad", "@{-1}", "main"] {
      await rejected(.create(name: name, startingAt: nil), detached)
    }
    try await GitBranchService.apply(.create(name: "feature/nested", startingAt: nil), snapshot: detached)
    let created = try await GitBranchService.snapshot(at: root)
    XCTAssertEqual(created.currentName, "feature/nested")
    XCTAssertEqual(created.currentCommit, detached.currentCommit)
  }

  func testRemoteTrackingAndSymbolicRemoteHead() async throws {
    let root = try await repository()
    _ = try await git(["remote", "add", "origin", root.path], root)
    _ = try await git(["fetch", "origin"], root)
    _ = try await git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], root)
    let snapshot = try await GitBranchService.snapshot(at: root)
    XCTAssertFalse(snapshot.branches.contains { $0.name == "origin/HEAD" })
    let remote = try choice("origin/main", snapshot)
    XCTAssertEqual(remote.suggestedLocalName, "main")
    try await GitBranchService.apply(.create(name: "tracking", startingAt: remote), snapshot: snapshot)
    let upstream = try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], root)
    XCTAssertEqual(upstream.trimmingCharacters(in: .newlines), "origin/main")
  }

  func testOccupiedWorktreeAndSubdirectoryRefused() async throws {
    let root = try await repository()
    let worktree = root.deletingLastPathComponent().appendingPathComponent("worktree with\nnewline \(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: worktree) }
    _ = try await git(["worktree", "add", "-b", "occupied", worktree.path], root)
    let snapshot = try await GitBranchService.snapshot(at: root)
    let occupied = try choice("occupied", snapshot)
    XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(occupied.checkedOutPath)).lastPathComponent,
      worktree.lastPathComponent)
    XCTAssertTrue(snapshot.isOccupied(occupied))
    XCTAssertFalse(snapshot.isOccupied(try choice("main", snapshot)))
    let ownWorktree = try await GitBranchService.snapshot(at: worktree)
    XCTAssertTrue(ownWorktree.canChange)
    XCTAssertFalse(ownWorktree.isOccupied(try choice("occupied", ownWorktree)))
    await rejected(.switchTo(occupied), snapshot)
    let sub = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    // Project-local Git commands intentionally do not discover a parent repository.
    do {
      _ = try await GitBranchService.snapshot(at: sub)
      XCTFail("A project subdirectory must not inherit its parent repository")
    } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    let subSnapshot = GitBranchSnapshot(root: sub, repositoryRoot: root,
      currentReference: snapshot.currentReference, currentCommit: snapshot.currentCommit,
      branches: snapshot.branches, changedFiles: 0)
    XCTAssertFalse(subSnapshot.canChange)
    await rejected(.create(name: "from-subdirectory", startingAt: nil), subSnapshot)
  }

  func testStaleHeadAndTargetRejected() async throws {
    let root = try await repository()
    _ = try await git(["branch", "feature"], root)
    let stale = try await GitBranchService.snapshot(at: root)
    _ = try await git(["switch", "feature"], root)
    await rejected(.switchTo(try choice("main", stale)), stale)
    try write("file", "new commit\n", root)
    try await commit(root)
    _ = try await git(["switch", "main"], root)
    await rejected(.switchTo(try choice("feature", stale)), stale)
    let current = try await GitBranchService.snapshot(at: root)
    XCTAssertEqual(current.currentName, "main")
  }

  @MainActor func testStoreRefreshesWorkspaceAndSettingsDismissesPicker() async throws {
    let root = try await repository()
    _ = try await git(["switch", "-c", "feature"], root)
    try write("file", "feature\n", root)
    try await commit(root)
    _ = try await git(["switch", "main"], root)
    let store = WorkspaceStore()
    store.project = root
    store.workspace.root = root
    await store.workspace.refreshGit()
    await store.workspace.openFile("file")
    store.draft = "keep this draft"
    store.openBranchPicker()
    XCTAssertTrue(store.showingBranchPicker)
    let snapshot = try await GitBranchService.snapshot(at: root)
    let success = await store.changeBranch(.switchTo(try choice("feature", snapshot)), snapshot: snapshot)
    XCTAssertTrue(success, store.branchChangeError ?? "")
    XCTAssertEqual(store.workspace.gitBranch, "feature")
    XCTAssertEqual(store.workspace.fileText, "feature\n")
    XCTAssertEqual(store.draft, "keep this draft")
    XCTAssertFalse(store.busy)
    XCTAssertFalse(store.workspace.gitBusy)
    XCTAssertFalse(store.showingBranchPicker)
    store.openBranchPicker()
    store.openSettings(.general)
    XCTAssertFalse(store.showingBranchPicker)
    XCTAssertFalse(store.commandEnabled("branch"))
    let refused = await store.changeBranch(.create(name: "wrong-context", startingAt: nil), snapshot: snapshot)
    XCTAssertFalse(refused)
    store.closeSettings()
    XCTAssertEqual(store.draft, "keep this draft")
    store.busy = true
    XCTAssertFalse(store.canChangeBranch)
    store.busy = false
    store.workspace.gitBusy = true
    XCTAssertFalse(store.canChangeBranch)
    store.workspace.gitBusy = false
    store.project = root.appendingPathComponent("another-project")
    let wrongProject = await store.changeBranch(.create(name: "wrong-project", startingAt: nil), snapshot: snapshot)
    XCTAssertFalse(wrongProject)
  }

  @MainActor func testCatalogDiscardsLateResult() async throws {
    let root = try await repository()
    let snapshot = try await GitBranchService.snapshot(at: root)
    let catalog = GitBranchCatalog()
    var pending: CheckedContinuation<GitBranchSnapshot, Never>?
    let old = Task {
      await catalog.load(root: root) { _ in
        await withCheckedContinuation { pending = $0 }
      }
    }
    while pending == nil { await Task.yield() }
    await catalog.load(root: root) { _ in throw AgentFailure(message: "Latest failure") }
    pending?.resume(returning: snapshot)
    await old.value
    XCTAssertNil(catalog.snapshot)
    XCTAssertEqual(catalog.error, "Latest failure")
    XCTAssertFalse(catalog.loading)
  }
}
