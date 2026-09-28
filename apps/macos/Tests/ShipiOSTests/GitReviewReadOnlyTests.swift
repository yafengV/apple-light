import XCTest
@testable import ShipiOS

@MainActor final class GitReviewReadOnlyTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-review-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let root = GitBranchService.canonicalRoot(folder.appendingPathComponent("Project"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"]] {
      _ = try await GitReviewService.checked(args, at: root)
    }
    try Data("original\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
    _ = try await GitReviewService.checked(["add", "."], at: root)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: root)
    try Data("changed\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
    let store = WorkspaceStore(dataRoot: folder.appendingPathComponent("Data"))
    await store.restore()
    store.workspace.root = root
    await store.workspace.refreshGit()
    return (store, root)
  }

  func testReadOnlySettingBlocksFileStageOnMainWorkspace() async throws {
    let (store, root) = try await fixture()
    store.library.gitPreferences.readOnlyReview = true
    await store.workspace.stage("tracked.txt", undo: false)
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertTrue(index.isEmpty, "Read-only review must not stage a file")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt")), "changed\n")
  }

  func testReadOnlyBlocksBatchHunkDiscardCommitAndUnstageWithoutChangingFiles() async throws {
    let (store, root) = try await fixture()
    let workspace = store.workspace
    let snapshot = try XCTUnwrap(workspace.batchSnapshot)
    let plan = try await GitDiscardService.prepare(snapshot)
    let file = try XCTUnwrap(workspace.gitFiles.first)
    let diff = try await GitReviewService.fileDiff(file, scope: .unstaged,
      arguments: workspace.reviewArguments, at: root)
    let hunk = try XCTUnwrap(diff.hunks.first)
    store.library.gitPreferences.readOnlyReview = true
    XCTAssertFalse(workspace.canModifyReview)
    await workspace.stageAll(snapshot)
    await workspace.applyHunk(.stage, file: file, hunk: hunk, snapshot: diff, project: root)
    await workspace.applyHunk(.revert, file: file, hunk: hunk, snapshot: diff, project: root)
    await workspace.prepareDiscard(snapshot)
    XCTAssertNil(workspace.discardPlan)
    await workspace.discard(plan)
    let cached = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertTrue(cached.isEmpty)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt")), "changed\n")
    store.library.gitPreferences.readOnlyReview = false
    await workspace.stage("tracked.txt", undo: false)
    let staged = try await GitReviewService.checked(["diff", "--cached"], at: root)
    XCTAssertFalse(staged.isEmpty)
    let head = try await GitReviewService.checked(["rev-parse", "HEAD"], at: root)
    workspace.reviewScope = .staged
    await workspace.loadDiff()
    let stagedSnapshot = try XCTUnwrap(workspace.batchSnapshot)
    store.library.gitPreferences.readOnlyReview = true
    await workspace.stage("tracked.txt", undo: true)
    await workspace.stageAll(stagedSnapshot)
    workspace.commitMessage = "Preserve this draft"
    let committed = await workspace.commit()
    XCTAssertFalse(committed)
    XCTAssertEqual(workspace.commitMessage, "Preserve this draft")
    let actualHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: root)
    let actualIndex = try await GitReviewService.checked(["diff", "--cached"], at: root)
    XCTAssertEqual(actualHead, head)
    XCTAssertEqual(actualIndex, staged)
  }

  func testTaskAndDetachedWorkspacesFollowCurrentPolicyAndRestoredPreferences() async throws {
    let (store, root) = try await fixture()
    let owner = WorkspaceTask(id: UUID().uuidString, project: root.path, title: "Source", runIDs: [])
    store.library.tasks = [owner]
    let resources = TaskWindowResources()
    resources.prepare(owner.id, store: store)
    let taskWorkspace = try XCTUnwrap(resources.panels.tasks[owner.id]?.workspace)
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    var preferences = store.library.gitPreferences
    preferences.readOnlyReview = true
    XCTAssertTrue(store.saveGitPreferences(preferences))
    for workspace in [store.workspace, taskWorkspace, detached.workspace] {
      XCTAssertFalse(workspace.canModifyReview)
      await workspace.stage("tracked.txt", undo: false)
    }
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertTrue(index.isEmpty)
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    await restored.restore()
    restored.workspace.root = root
    XCTAssertFalse(restored.workspace.canModifyReview)
    preferences.readOnlyReview = false
    XCTAssertTrue(store.saveGitPreferences(preferences))
    for workspace in [store.workspace, taskWorkspace, detached.workspace] { XCTAssertTrue(workspace.canModifyReview) }
    await taskWorkspace.stage("tracked.txt", undo: false)
    let allowedIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertEqual(allowedIndex.trimmingCharacters(in: .whitespacesAndNewlines), "tracked.txt")
    resources.shutdown()
    detached.shutdown()
  }

  func testAuthorizationRejectsBatchWriteAfterPreflightAndOldProjectIdentity() async throws {
    let (store, root) = try await fixture()
    let snapshot = try XCTUnwrap(store.workspace.batchSnapshot)
    let check = store.workspace.gitMutationAuthorization(at: root)
    do {
      try await GitBatchService.apply(snapshot, authorize: {
        store.library.gitPreferences.readOnlyReview = true
        try check()
      })
      XCTFail("Policy changed before writing the index")
    } catch { XCTAssertTrue(error.localizedDescription.contains("只读")) }
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertTrue(index.isEmpty)
    store.library.gitPreferences.readOnlyReview = false
    store.workspace.setProject(nil)
    store.workspace.root = root
    XCTAssertThrowsError(try check(), "Old preflight must not survive navigation away and back")
  }

  func testAuthorizationRejectsHunkAndDiscardAfterPreflight() async throws {
    let (store, root) = try await fixture()
    let workspace = store.workspace
    let snapshot = try XCTUnwrap(workspace.batchSnapshot)
    let file = try XCTUnwrap(workspace.gitFiles.first)
    let diff = try await GitReviewService.fileDiff(file, scope: .unstaged,
      arguments: workspace.reviewArguments, at: root)
    let hunk = try XCTUnwrap(diff.hunks.first)
    let check = workspace.gitMutationAuthorization(at: root)
    let deny: GitMutationAuthorization = {
      store.library.gitPreferences.readOnlyReview = true
      try check()
    }
    for action in [GitHunkAction.stage, .revert] {
      store.library.gitPreferences.readOnlyReview = false
      do {
        try await GitHunkService.apply(action, path: file.path, hunkID: hunk.id,
          snapshot: diff, at: root, authorize: deny)
        XCTFail("Hunk write must be rejected")
      } catch { XCTAssertTrue(error.localizedDescription.contains("只读")) }
    }
    store.library.gitPreferences.readOnlyReview = false
    let plan = try await GitDiscardService.prepare(snapshot)
    do {
      try await GitDiscardService.execute(plan, authorize: deny)
      XCTFail("Discard write must be rejected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("只读")) }
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertTrue(index.isEmpty)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt")), "changed\n")
  }

  func testAuthorizationStopsNewBranchAndCommitSelectionBeforeMutation() async throws {
    let (store, root) = try await fixture()
    let selection = try await GitCommitSelection.capture(at: root, includeUnstaged: true, newBranch: "new-review")
    let check = store.workspace.gitMutationAuthorization(at: root)
    do {
      try await selection.apply(authorize: {
        store.library.gitPreferences.readOnlyReview = true
        try check()
      })
      XCTFail("New branch must not be created")
    } catch { XCTAssertTrue(error.localizedDescription.contains("只读")) }
    let branch = try await GitReviewService.checked(["branch", "--show-current"], at: root)
    let refs = try await GitReviewService.checked(["branch", "--list", "new-review"], at: root)
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: root)
    XCTAssertEqual(branch.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    XCTAssertTrue(refs.isEmpty)
    XCTAssertTrue(index.isEmpty)
  }

}
