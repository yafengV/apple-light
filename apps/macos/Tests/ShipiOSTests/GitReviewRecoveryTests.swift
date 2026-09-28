import XCTest
@testable import ShipiOS

@MainActor final class GitReviewRecoveryTests: XCTestCase {
  private func fixture() async throws -> (DeveloperWorkspace, URL, Data) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let root = GitBranchService.canonicalRoot(folder)
    for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"]] {
      _ = try await GitReviewService.checked(arguments, at: root)
    }
    try Data("original\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await GitReviewService.checked(["add", "."], at: root)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: root)
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    try Data("changed\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    return (workspace, root, index)
  }

  func testUnreadableIndexCannotBecomeRepositoryCreationOrRetainMutationSnapshots() async throws {
    let (workspace, root, _) = try await fixture()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertNotNil(workspace.batchSnapshot)
    await workspace.openFile("file.txt")
    workspace.commitMessage = "Keep my draft"
    try Data("invalid-index".utf8).write(to: root.appendingPathComponent(".git/index"))
    let discovered = try await GitRepositoryContext.resolve(at: root)
    XCTAssertEqual(discovered, root, "Git discovery still succeeds with a damaged index")
    await workspace.refreshGit()
    XCTAssertFalse(workspace.gitAvailable)
    XCTAssertFalse(workspace.canInitializeGit, "An unreadable repository is not an absent repository")
    XCTAssertFalse(workspace.canModifyReview)
    XCTAssertNotNil(workspace.error, "The actual status failure must remain available for retry")
    XCTAssertEqual(workspace.error, workspace.gitReadError)
    XCTAssertEqual(workspace.gitRepositoryRoot, root)
    XCTAssertNil(workspace.batchSnapshot)
    XCTAssertTrue(workspace.reviewArguments.isEmpty)
    XCTAssertTrue(workspace.gitFiles.isEmpty)
    XCTAssertTrue(workspace.diff.isEmpty)
    XCTAssertEqual(workspace.commitMessage, "Keep my draft")
    XCTAssertEqual(workspace.selectedFile, "file.txt")
    XCTAssertEqual(workspace.fileText, "changed\n")
  }

  func testRetryRecoversSameScopeAndDraftAndAllowsARealStage() async throws {
    let (workspace, root, index) = try await fixture()
    await workspace.openFile("file.txt")
    workspace.commitMessage = "Preserved commit"
    workspace.reviewScope = .staged
    await workspace.loadDiff()
    let damaged = Data("invalid-index".utf8)
    try damaged.write(to: root.appendingPathComponent(".git/index"))
    await workspace.refreshGit()
    let firstError = try XCTUnwrap(workspace.gitReadError)
    await workspace.refreshGit()
    XCTAssertEqual(workspace.gitReadError, firstError)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), damaged)
    try index.write(to: root.appendingPathComponent(".git/index"))
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertTrue(workspace.canCommit)
    XCTAssertTrue(workspace.canModifyReview)
    XCTAssertNil(workspace.gitReadError)
    XCTAssertNil(workspace.error)
    XCTAssertEqual(workspace.reviewScope, .staged)
    XCTAssertTrue(workspace.visibleChanges.isEmpty)
    XCTAssertEqual(workspace.commitMessage, "Preserved commit")
    XCTAssertEqual(workspace.fileText, "changed\n")
    workspace.reviewScope = .unstaged
    await workspace.loadDiff()
    await workspace.stage("file.txt", undo: false)
    let staged = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertEqual(staged.trimmingCharacters(in: .newlines), "file.txt")
  }

  func testFailedReadInvalidatesOpenDialogsAndOldAuthorizationsUntilRetry() async throws {
    let (workspace, root, index) = try await fixture()
    let snapshot = try XCTUnwrap(workspace.batchSnapshot)
    let plan = try await GitDiscardService.prepare(snapshot)
    let authorization = workspace.gitMutationAuthorization(at: root)
    let repositoryAuthorization = workspace.gitRepositoryAuthorization(at: root)
    workspace.discardPlan = plan
    workspace.showingCommitPush = true
    workspace.showingPullRequest = true
    workspace.commitMessage = "Keep this"
    try Data("invalid-index".utf8).write(to: root.appendingPathComponent(".git/index"))
    await workspace.refreshGit()
    XCTAssertFalse(workspace.showingCommitPush)
    XCTAssertFalse(workspace.showingPullRequest)
    XCTAssertNil(workspace.discardPlan)
    XCTAssertThrowsError(try authorization())
    XCTAssertThrowsError(try repositoryAuthorization())
    let expectedError = workspace.gitReadError
    await workspace.loadDiff()
    XCTAssertEqual(workspace.gitReadError, expectedError)
    XCTAssertEqual(workspace.error, expectedError, "A selection callback cannot erase the repository error")
    // Repair the fixture without refreshing: old cards and commands must still
    // be disabled, even when a Git write itself could now succeed.
    try index.write(to: root.appendingPathComponent(".git/index"))
    await workspace.stageAll(snapshot)
    await workspace.discard(plan)
    await workspace.stage("file.txt", undo: false)
    let committed = await workspace.commit()
    let initialized = await workspace.initializeGit(at: root)
    XCTAssertFalse(committed)
    XCTAssertFalse(initialized)
    XCTAssertEqual(workspace.commitMessage, "Keep this")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "changed\n")
    let staged = try await GitReviewService.checked(["diff", "--cached"], at: root)
    XCTAssertTrue(staged.isEmpty)
    await workspace.refreshGit()
    XCTAssertNil(workspace.gitReadError)
    XCTAssertTrue(workspace.gitAvailable)
  }

  func testBrokenNearestMetadataDoesNotOfferInitializationOrUseParentUntilFixed() async throws {
    let (_, root, _) = try await fixture()
    let child = root.appendingPathComponent("Child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let workspace = DeveloperWorkspace()
    workspace.root = GitBranchService.canonicalRoot(child)
    let metadata = child.appendingPathComponent(".git")
    let broken = Data("gitdir: unavailable-fixture-directory\n".utf8)
    try broken.write(to: metadata)
    await workspace.refreshGit()
    XCTAssertFalse(workspace.gitAvailable)
    XCTAssertNotNil(workspace.gitReadError)
    XCTAssertNil(workspace.gitRepositoryRoot)
    XCTAssertFalse(workspace.canInitializeGit)
    let initialized = await workspace.initializeGit(at: try XCTUnwrap(workspace.root))
    XCTAssertFalse(initialized)
    XCTAssertEqual(try Data(contentsOf: metadata), broken)
    try FileManager.default.removeItem(at: metadata)
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertEqual(workspace.gitRepositoryRoot, root)
    XCTAssertNil(workspace.gitReadError)
    XCTAssertFalse(workspace.canInitializeGit)
  }

  func testRemovedRepositoryBecomesMissingOnlyAfterSuccessfulDiscovery() async throws {
    let (workspace, root, _) = try await fixture()
    workspace.commitMessage = "Preserve draft"
    try Data("invalid-index".utf8).write(to: root.appendingPathComponent(".git/index"))
    await workspace.refreshGit()
    XCTAssertFalse(workspace.canInitializeGit)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
    await workspace.refreshGit()
    XCTAssertFalse(workspace.gitAvailable)
    XCTAssertNil(workspace.gitReadError)
    XCTAssertNil(workspace.gitRepositoryRoot)
    XCTAssertNil(workspace.error)
    XCTAssertTrue(workspace.canInitializeGit)
    let created = await workspace.initializeGit(at: root)
    XCTAssertTrue(created)
    XCTAssertTrue(workspace.reviewCommits.isEmpty)
    XCTAssertEqual(workspace.commitMessage, "Preserve draft")
  }

  func testMissingProjectDirectoryIsRetryableButCannotInitializeIt() async throws {
    let (workspace, root, _) = try await fixture()
    try FileManager.default.removeItem(at: root)
    await workspace.refreshGit()
    XCTAssertNotNil(workspace.gitReadError)
    XCTAssertFalse(workspace.gitAvailable)
    XCTAssertFalse(workspace.canInitializeGit)
    let initialized = await workspace.initializeGit(at: root)
    XCTAssertFalse(initialized)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await workspace.refreshGit()
    XCTAssertNil(workspace.gitReadError)
    XCTAssertTrue(workspace.canInitializeGit)
    workspace.setProject(nil)
    XCTAssertNil(workspace.error)
    XCTAssertNil(workspace.gitReadError)
    XCTAssertFalse(workspace.canInitializeGit)
  }

  func testTaskAndDetachedRetryRemainBoundToSourceWhenMainProjectDiffers() async throws {
    let (_, source, index) = try await fixture()
    let (mainWorkspace, main, _) = try await fixture()
    let data = main.deletingLastPathComponent().appendingPathComponent("review-data-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: data) }
    let store = WorkspaceStore(dataRoot: data)
    store.project = main
    store.workspace.root = main
    store.workspace.gitRepositoryRoot = mainWorkspace.gitRepositoryRoot
    store.draft = "Keep main draft"
    let owner = WorkspaceTask(id: "recovery-owner", project: source.path, title: "Source", runIDs: [])
    store.library.tasks = [owner]
    let resources = TaskWindowResources()
    resources.prepare(owner.id, store: store)
    defer { resources.shutdown() }
    let task = try XCTUnwrap(resources.panels.tasks[owner.id]?.workspace)
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    defer { detached.shutdown() }
    await Task.yield()
    for workspace in [task, detached.workspace] {
      await workspace.refreshFiles()
      await workspace.refreshGit()
      workspace.commitMessage = "Source commit"
    }
    try Data("invalid-index".utf8).write(to: source.appendingPathComponent(".git/index"))
    for workspace in [task, detached.workspace] {
      await workspace.refreshGit()
      XCTAssertFalse(workspace.canInitializeGit)
      XCTAssertNotNil(workspace.gitReadError)
      XCTAssertEqual(workspace.gitRepositoryRoot?.path, source.path)
    }
    try index.write(to: source.appendingPathComponent(".git/index"))
    for workspace in [task, detached.workspace] {
      await workspace.refreshGit()
      XCTAssertTrue(workspace.gitAvailable)
      XCTAssertNil(workspace.gitReadError)
      XCTAssertEqual(workspace.commitMessage, "Source commit")
      XCTAssertEqual(workspace.root?.path, source.path)
    }
    XCTAssertEqual(detached.owner, owner.id)
    XCTAssertEqual(store.project, main)
    XCTAssertEqual(store.workspace.root, main)
    XCTAssertEqual(store.draft, "Keep main draft")
  }

  func testBranchEntryAndCapturedBranchChangeCannotBypassFailedRead() async throws {
    let (_, root, index) = try await fixture()
    let data = root.deletingLastPathComponent().appendingPathComponent("review-data-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: data) }
    let store = WorkspaceStore(dataRoot: data)
    store.project = root
    store.workspace.root = root
    await store.workspace.refreshGit()
    let snapshot = try await GitBranchService.snapshot(at: root)
    XCTAssertTrue(store.canChangeBranch)
    try Data("invalid-index".utf8).write(to: root.appendingPathComponent(".git/index"))
    await store.workspace.refreshGit()
    XCTAssertFalse(store.canChangeBranch)
    store.openBranchPicker()
    XCTAssertFalse(store.showingBranchPicker)
    // Even a repaired index cannot make the stale UI write before Retry.
    try index.write(to: root.appendingPathComponent(".git/index"))
    let changed = await store.changeBranch(.create(name: "must-not-exist", startingAt: nil), snapshot: snapshot)
    XCTAssertFalse(changed)
    XCTAssertTrue(store.branchChangeError?.contains("读取失败") == true)
    let created = try await GitReviewService.checked(["branch", "--list", "must-not-exist"], at: root)
    XCTAssertTrue(created.isEmpty)
    await store.workspace.refreshGit()
    XCTAssertTrue(store.canChangeBranch)
  }
}
