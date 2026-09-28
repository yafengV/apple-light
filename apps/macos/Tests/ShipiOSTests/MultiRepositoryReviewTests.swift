import XCTest
@testable import ShipiOS

@MainActor final class MultiRepositoryReviewTests: XCTestCase {
  private func fixture() async throws -> (URL, URL, WorkspaceStore) {
    let container = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory
      .appendingPathComponent("multi-review-\(UUID())"))
    let primary = container.appendingPathComponent("primary", isDirectory: true)
    let secondary = container.appendingPathComponent("secondary", isDirectory: true)
    for (folder, branch) in [(primary, "main"), (secondary, "other")] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      _ = try await GitReviewService.checked(["init", "-q", "-b", branch], at: folder)
      _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: folder)
      _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: folder)
      try Data("original \(branch)\n".utf8).write(to: folder.appendingPathComponent("shared.txt"))
      _ = try await GitReviewService.checked(["add", "."], at: folder)
      _ = try await GitReviewService.checked(["commit", "-qm", "Initial \(branch)"], at: folder)
      try Data("changed \(branch)\n".utf8).write(to: folder.appendingPathComponent("shared.txt"))
    }
    let store = WorkspaceStore(dataRoot: container.appendingPathComponent("Data"))
    store.project = primary
    store.library.projects = [primary.path]
    store.library.projectAdditionalFolders[primary.path] = [secondary.path]
    store.workspace.root = primary
    store.bindGitReviewPolicy(to: store.workspace)
    await store.workspace.refreshGit()
    addTeardownBlock { @MainActor in
      store.workspace.setProject(nil)
      try? FileManager.default.removeItem(at: container)
    }
    return (primary, secondary, store)
  }

  func testDiscoveryDefaultsToPrimaryAndDeduplicatesNestedAttachedFolders() async throws {
    let (primary, secondary, store) = try await fixture()
    let child = primary.appendingPathComponent("App")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    store.workspace.setAdditionalFileRoots([child, secondary, secondary])
    await store.workspace.refreshGit()
    XCTAssertEqual(store.workspace.reviewRepositories.map(\.root), [primary, secondary])
    XCTAssertTrue(store.workspace.isPrimaryReviewRepository)
    XCTAssertEqual(store.workspace.gitRoot, primary)
    XCTAssertEqual(store.workspace.root, primary)
    XCTAssertNil(store.workspace.selectedReviewRepository)
  }

  func testSecondaryStageUnstageCommitAndPushLeavePrimaryIndexAndHistoryAlone() async throws {
    let (primary, secondary, store) = try await fixture()
    let workspace = store.workspace
    let originalHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: primary)
    store.draft = "Keep task draft"
    let selected = await workspace.selectReviewRepository(secondary.path)
    XCTAssertTrue(selected)
    XCTAssertEqual(workspace.gitBranch, "other")
    XCTAssertFalse(workspace.isPrimaryReviewRepository)
    await workspace.stage("shared.txt", undo: false)
    XCTAssertNil(workspace.error)
    let primaryIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: primary)
    let secondaryIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: secondary)
    XCTAssertEqual(primaryIndex, "")
    XCTAssertEqual(secondaryIndex.trimmingCharacters(in: .newlines), "shared.txt")
    await workspace.stage("shared.txt", undo: true)
    let empty = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: secondary)
    XCTAssertEqual(empty, "")
    workspace.commitMessage = "Commit secondary"
    let committed = await store.performGitAction(.commit, in: workspace, includeUnstaged: true)
    XCTAssertTrue(committed, workspace.error ?? "Commit failed")
    let primaryHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: primary)
    XCTAssertEqual(primaryHead, originalHead)
    let remote = primary.deletingLastPathComponent().appendingPathComponent("remote.git")
    _ = try await GitReviewService.checked(["init", "-q", "--bare", remote.path], at: secondary)
    _ = try await GitReviewService.checked(["remote", "add", "origin", remote.path], at: secondary)
    let pushed = await workspace.push(remote: "origin", destination: "other", forceWithLease: false)
    XCTAssertTrue(pushed, workspace.error ?? "Push failed")
    let published = try await GitReviewService.checked(["rev-parse", "refs/heads/other"], at: remote)
    let secondaryHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: secondary)
    XCTAssertEqual(published, secondaryHead)
    let taskBranch = await store.branchForTaskHistory()
    XCTAssertEqual(taskBranch, "main")
    XCTAssertEqual(workspace.root, primary)
    XCTAssertEqual(store.project, primary)
    XCTAssertEqual(store.draft, "Keep task draft")
  }

  func testRepositoryDraftsAndModelReviewRemainSeparateForSameNamedFiles() async throws {
    let (primary, secondary, store) = try await fixture()
    let workspace = store.workspace
    workspace.commitMessage = "Primary draft"
    workspace.collapsedReviewFiles = ["shared.txt"]
    _ = await workspace.selectReviewRepository(secondary.path)
    XCTAssertEqual(workspace.commitMessage, "")
    XCTAssertTrue(workspace.collapsedReviewFiles.isEmpty)
    workspace.commitMessage = "Secondary draft"
    let snapshot = try await workspace.modelReviewSnapshot(scope: .uncommitted)
    XCTAssertEqual(snapshot.repositoryRoot, secondary.path)
    XCTAssertTrue(snapshot.diff.contains("changed other"))
    XCTAssertFalse(snapshot.diff.contains("changed main"))
    _ = await workspace.selectReviewRepository(primary.path)
    XCTAssertEqual(workspace.commitMessage, "Primary draft")
    XCTAssertEqual(workspace.collapsedReviewFiles, ["shared.txt"])
    _ = await workspace.selectReviewRepository(secondary.path)
    XCTAssertEqual(workspace.commitMessage, "Secondary draft")
  }

  func testRemovedRepositoryInvalidatesMutationAndOldBatchEvenAfterReattachment() async throws {
    let (primary, secondary, store) = try await fixture()
    let workspace = store.workspace
    workspace.commitMessage = "Primary draft"
    _ = await workspace.selectReviewRepository(secondary.path)
    let oldBatch = try XCTUnwrap(workspace.batchSnapshot)
    let authorize = workspace.gitMutationAuthorization(at: secondary)
    workspace.setAdditionalFileRoots([])
    XCTAssertThrowsError(try authorize()) { XCTAssertTrue($0 is CancellationError) }
    await workspace.refreshGit()
    XCTAssertEqual(workspace.gitRoot, primary)
    XCTAssertEqual(workspace.commitMessage, "Primary draft")
    await workspace.stageAll(oldBatch)
    workspace.setAdditionalFileRoots([secondary])
    await workspace.refreshGit()
    _ = await workspace.selectReviewRepository(secondary.path)
    XCTAssertThrowsError(try authorize()) { XCTAssertTrue($0 is CancellationError) }
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: secondary)
    XCTAssertEqual(index, "")
  }

  func testRepositorySelectionCannotChangeDuringMutationsOrLastTurnAndHonorsReadOnly() async throws {
    let (primary, secondary, store) = try await fixture()
    let workspace = store.workspace
    for action in 0..<3 {
      workspace.gitBusy = action == 0
      workspace.gitActionRunning = action == 1
      workspace.generatingCommitMessage = action == 2
      let changed = await workspace.selectReviewRepository(secondary.path)
      XCTAssertFalse(changed)
      XCTAssertEqual(workspace.gitRoot, primary)
    }
    workspace.gitBusy = false; workspace.gitActionRunning = false; workspace.generatingCommitMessage = false
    workspace.reviewScope = .lastTurn
    let changed = await workspace.selectReviewRepository(secondary.path)
    XCTAssertFalse(changed)
    workspace.reviewScope = .unstaged
    _ = await workspace.selectReviewRepository(secondary.path)
    store.library.gitPreferences.readOnlyReview = true
    await workspace.stage("shared.txt", undo: false)
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: secondary)
    XCTAssertEqual(index, "")
    XCTAssertFalse(workspace.canModifyReview)
    store.library.gitPreferences.readOnlyReview = false
    XCTAssertTrue(workspace.canModifyReview)
    XCTAssertFalse(workspace.isPrimaryReviewRepository)
    await store.createPullRequest(in: workspace, draft: true)
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertNil(workspace.pullRequestDraft.context)
  }

  func testBrokenSecondaryRepositoryCanBeSelectedReportedRepairedAndSwitchedAway() async throws {
    let (primary, secondary, store) = try await fixture()
    let index = secondary.appendingPathComponent(".git/index")
    let original = try Data(contentsOf: index)
    try Data("broken index".utf8).write(to: index)
    await store.workspace.refreshGit()
    XCTAssertTrue(store.workspace.gitAvailable)
    let changed = await store.workspace.selectReviewRepository(secondary.path)
    XCTAssertFalse(changed)
    XCTAssertEqual(store.workspace.gitRepositoryRoot, secondary)
    XCTAssertNotNil(store.workspace.gitReadError)
    XCTAssertFalse(store.workspace.canModifyReview)
    XCTAssertEqual(store.workspace.reviewRepositories.count, 2)
    let returned = await store.workspace.selectReviewRepository(primary.path)
    XCTAssertTrue(returned)
    try original.write(to: index)
    let recovered = await store.workspace.selectReviewRepository(secondary.path)
    XCTAssertTrue(recovered)
    XCTAssertNil(store.workspace.gitReadError)
  }

  func testReviewCommentsValidateAttachedRepositoryAndRejectRemovedSource() async throws {
    let (primary, secondary, store) = try await fixture()
    let task = WorkspaceTask(id: "review", project: primary.path, title: "Review", runIDs: [])
    store.library.tasks = [task]
    let anchor = ReviewAnchor(project: primary.path, path: "shared.txt", scope: "未暂存",
      revision: "working tree", fingerprint: "patch", oldLine: 1, newLine: 1,
      code: "changed other", repository: secondary.path)
    store.beginReviewComment(anchor, taskID: task.id)
    let comment = try XCTUnwrap(store.reviewComments(taskID: task.id).first)
    store.updateReviewComment(comment.id, text: "Check secondary", taskID: task.id)
    store.saveReviewComment(comment.id, taskID: task.id)
    let comments = store.reviewComments(taskID: task.id)
    let prompt = try store.promptWithReviewComments("Fix", comments: comments, project: primary.path)
    XCTAssertTrue(prompt.contains(secondary.path))
    store.library.projectAdditionalFolders[primary.path] = []
    XCTAssertThrowsError(try store.promptWithReviewComments("Fix", comments: comments, project: primary.path))
    store.beginReviewComment(anchor, taskID: task.id)
    XCTAssertEqual(store.reviewComments(taskID: task.id).count, 1)
  }

  func testReviewReplyUsesCapturedAttachedScopeAfterRemovalAndRejectsUnrecordedScope() async throws {
    let (primary, secondary, store) = try await fixture()
    let run = AgentRun(id: "review", kind: "chat", project: primary.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .object([
        "conversation_kind": .string("review"), "review_repository_root": .string(secondary.path),
        "additional_folders": .array([.string(secondary.path)])]), result: nil)
    store.library.projectAdditionalFolders[primary.path] = []
    XCTAssertEqual(store.responseFileRoot(for: run), secondary)
    let unrecorded = AgentRun(id: "unrecorded", kind: "chat", project: primary.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .object(["conversation_kind": .string("review"),
        "review_repository_root": .string(secondary.path)]), result: nil)
    XCTAssertNil(store.responseFileRoot(for: unrecorded))
  }

  func testLastTurnRetainsPatchesFromAllRepositoriesAndResolvesOnlyAttachedExternalFiles() async throws {
    let (primary, secondary, store) = try await fixture()
    let text = """
    diff --git a/shared.txt b/shared.txt
    --- a/shared.txt
    +++ b/shared.txt
    @@ -1 +1 @@
    -original main
    +changed main
    diff --git a/../secondary/shared.txt b/../secondary/shared.txt
    --- a/../secondary/shared.txt
    +++ b/../secondary/shared.txt
    @@ -1 +1 @@
    -original other
    +changed other
    """
    let files = CodexTurnDiffFiles.parse(text)
    XCTAssertEqual(files.map(\.path), ["shared.txt", "../secondary/shared.txt"])
    XCTAssertEqual(files.count, 2)
    let source = LastTurnReviewSource(runID: "last-turn", root: primary, diff: nil)
    let snapshot = LastTurnReviewSnapshot(source: source, unifiedDiff: text, files: files,
      patches: Dictionary(uniqueKeysWithValues: files.map { ($0.id, ReviewDiff($0.patch)) }))
    store.workspace.lastTurnReviewSource = { source }
    store.workspace.lastTurnDataRoot = store.dataRoot
    store.workspace.readLastTurnSnapshot = { _, _ in snapshot }
    _ = await store.workspace.selectReviewRepository(secondary.path)
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    XCTAssertEqual(store.workspace.lastTurnReview?.files, files)
    XCTAssertEqual(store.workspace.diff, text)
    let first = try store.workspace.lastTurnFileLocation(files[0].path, base: primary)
    let second = try store.workspace.lastTurnFileLocation(files[1].path, base: primary)
    XCTAssertEqual(first.url, primary.appendingPathComponent("shared.txt"))
    XCTAssertEqual(second.url, secondary.appendingPathComponent("shared.txt"))
    store.workspace.setAdditionalFileRoots([])
    XCTAssertThrowsError(try store.workspace.lastTurnFileLocation(files[1].path, base: primary))
    let escape = primary.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: secondary.appendingPathComponent("shared.txt"))
    XCTAssertThrowsError(try store.workspace.lastTurnFileLocation("escape", base: primary))
  }

  func testSavedSelectionRoundTripsAndRemovedOrUnrelatedHintsFallBackToPrimary() async throws {
    let (primary, secondary, store) = try await fixture()
    _ = await store.workspace.selectReviewRepository(secondary.path)
    let layout = store.workspaceTabLayoutSnapshot
    let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONEncoder().encode(layout))
    XCTAssertEqual(saved.reviewRepository, secondary.path)
    let restored = DeveloperWorkspace()
    restored.root = primary
    restored.setAdditionalFileRoots([secondary])
    restored.restoreReviewRepository(saved.reviewRepository)
    await restored.refreshGit()
    XCTAssertEqual(restored.gitRoot, secondary)
    restored.setAdditionalFileRoots([])
    restored.restoreReviewRepository(saved.reviewRepository)
    await restored.refreshGit()
    XCTAssertEqual(restored.gitRoot, primary)
    restored.restoreReviewRepository("relative/path")
    await restored.refreshGit()
    XCTAssertEqual(restored.gitRoot, primary)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
    legacy.removeValue(forKey: "reviewRepository")
    XCTAssertNil(try JSONDecoder().decode(WorkspaceTabLayout.self,
      from: JSONSerialization.data(withJSONObject: legacy)).reviewRepository)
    restored.setProject(nil)
  }

  func testTaskAndDetachedWindowsRestoreOwnerRepositoryWithoutChangingMainTaskScope() async throws {
    let (primary, secondary, store) = try await fixture()
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    let owner = WorkspaceTask(id: "owner", project: primary.path, title: "Owner", runIDs: [])
    store.library.tasks = [owner]; store.selection = owner.id
    store.restoreWorkspaceTabLayout()
    store.openReviewTab()
    _ = await store.workspace.selectReviewRepository(secondary.path)
    store.captureWorkspaceTabLayout()
    store.saveLibrary()
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    defer { detached.shutdown() }
    await detached.workspace.refreshGit()
    XCTAssertEqual(detached.workspace.gitRoot, secondary)
    _ = await detached.workspace.selectReviewRepository(primary.path)
    detached.saveScope(store: store)
    await store.workspace.refreshGit()
    XCTAssertEqual(store.workspace.gitRoot, primary)
    XCTAssertEqual(store.library.workspaceTabLayouts[owner.id]?.reviewRepository, primary.path)
    let resources = TaskWindowResources()
    resources.prepare(owner.id, store: store)
    defer { resources.shutdown() }
    let panels = try XCTUnwrap(resources.panels.tasks[owner.id])
    let tabs = try XCTUnwrap(resources.tasks[owner.id])
    _ = await panels.workspace.selectReviewRepository(secondary.path)
    await panels.workspace.refreshGit()
    _ = await panels.workspace.selectReviewRepository(secondary.path)
    let saved = tabs.layoutSnapshot
    XCTAssertEqual(saved.content.reviewRepository, secondary.path)
    XCTAssertEqual(store.workspace.root, primary)
    XCTAssertEqual(panels.workspace.root, primary)
    resources.captureLayouts()
    let restarted = TaskWindowResources()
    restarted.prepare(owner.id, store: store, windowID: resources.id)
    defer { restarted.shutdown() }
    let restored = try XCTUnwrap(restarted.panels.tasks[owner.id]?.workspace)
    await restored.refreshGit()
    XCTAssertEqual(restored.gitRoot, secondary)
    XCTAssertEqual(restored.root, primary)
    XCTAssertEqual(store.workspace.gitRoot, primary)
  }

  func testDefaultSelectionWithoutPrimaryGitRepositoryRestoresFirstAttachedDraft() async throws {
    let (first, second, store) = try await fixture()
    let noGit = first.deletingLastPathComponent().appendingPathComponent("no-git", isDirectory: true)
    try FileManager.default.createDirectory(at: noGit, withIntermediateDirectories: true)
    let workspace = DeveloperWorkspace()
    workspace.root = noGit
    workspace.setAdditionalFileRoots([first, second])
    await workspace.refreshGit()
    XCTAssertEqual(workspace.gitRoot, first)
    XCTAssertFalse(workspace.isPrimaryReviewRepository)
    workspace.commitMessage = "First attached draft"
    _ = await workspace.selectReviewRepository(second.path)
    workspace.commitMessage = "Second attached draft"
    workspace.restoreReviewRepository(nil)
    await workspace.refreshGit()
    XCTAssertEqual(workspace.gitRoot, first)
    XCTAssertEqual(workspace.commitMessage, "First attached draft")
    XCTAssertEqual(store.workspace.root, first)
    workspace.setProject(nil)
  }
}
