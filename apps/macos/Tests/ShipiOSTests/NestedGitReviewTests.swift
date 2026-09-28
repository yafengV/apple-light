import XCTest
@testable import ShipiOS

@MainActor final class NestedGitReviewTests: XCTestCase {
  private func fixture() async throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nested-review-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let repository = GitBranchService.canonicalRoot(folder)
    let child = repository.appendingPathComponent("App")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q", "-b", "main"], at: repository)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: repository)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: repository)
    for path in ["App/inside.txt", "outside.txt"] {
      try Data("original\n".utf8).write(to: repository.appendingPathComponent(path))
    }
    _ = try await GitReviewService.checked(["add", "."], at: repository)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: repository)
    for path in ["App/inside.txt", "outside.txt"] {
      try Data("changed\n".utf8).write(to: repository.appendingPathComponent(path))
    }
    return (repository, GitBranchService.canonicalRoot(child))
  }

  func testProjectInsideRepositoryShowsWholeRepositoryWithoutChangingProjectDirectory() async throws {
    let (_, child) = try await fixture()
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertTrue(workspace.canCommit)
    XCTAssertEqual(Set(workspace.visibleChanges.map(\.path)), ["App/inside.txt", "outside.txt"])
    XCTAssertEqual(workspace.root, child)
    await workspace.refreshFiles()
    XCTAssertEqual(workspace.files, ["inside.txt"])
  }

  func testNestedProjectBatchAndCommitIncludeBothDirectoriesAndKeepTaskDraft() async throws {
    let (repository, child) = try await fixture()
    let store = WorkspaceStore(dataRoot: repository.appendingPathComponent(".private-data"))
    store.project = child
    store.workspace.root = child
    store.draft = "Preserve task draft"
    await store.workspace.refreshGit()
    let workspace = store.workspace
    let snapshot = try XCTUnwrap(workspace.batchSnapshot)
    XCTAssertEqual(snapshot.root.path, repository.path)
    await workspace.stageAll(snapshot)
    XCTAssertNil(workspace.error)
    workspace.reviewScope = .staged
    await workspace.loadDiff()
    XCTAssertEqual(Set(workspace.visibleChanges.map(\.path)), ["App/inside.txt", "outside.txt"])
    await workspace.stageAll(try XCTUnwrap(workspace.batchSnapshot))
    let emptyIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertTrue(emptyIndex.isEmpty)
    workspace.reviewScope = .unstaged
    await workspace.loadDiff()
    workspace.commitMessage = "Commit both directories"
    let committed = await store.performGitAction(.commit, in: workspace, includeUnstaged: true)
    XCTAssertTrue(committed, workspace.error ?? "Commit failed")
    let committedPaths = try await GitReviewService.checked(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"], at: repository)
    XCTAssertEqual(Set(committedPaths.split(separator: "\n").map(String.init)), ["App/inside.txt", "outside.txt"])
    XCTAssertEqual(store.project, child)
    XCTAssertEqual(workspace.root, child)
    XCTAssertEqual(store.draft, "Preserve task draft")
  }

  func testNestedProjectCanStageSiblingHunkAndDiscardItsWorkingChange() async throws {
    let (repository, child) = try await fixture()
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    let file = try XCTUnwrap(workspace.gitFiles.first { $0.path == "outside.txt" })
    let patch = try await GitReviewService.fileDiff(file, scope: .unstaged,
      arguments: workspace.reviewArguments, at: try XCTUnwrap(workspace.gitRoot))
    await workspace.applyHunk(.stage, file: file, hunk: try XCTUnwrap(patch.hunks.first),
      snapshot: patch, project: try XCTUnwrap(workspace.gitRoot))
    XCTAssertNil(workspace.error)
    let staged = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertEqual(staged.trimmingCharacters(in: .newlines), "outside.txt")
    await workspace.stage("outside.txt", undo: true)
    await workspace.prepareDiscard(try XCTUnwrap(workspace.batchSnapshot), path: "outside.txt")
    await workspace.discard(try XCTUnwrap(workspace.discardPlan))
    XCTAssertNil(workspace.error)
    XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("outside.txt")), "original\n")
    XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("inside.txt")), "changed\n")
    XCTAssertEqual(workspace.root, child)
  }

  func testBranchSwitchAndPushUseRepositoryWhileTaskStaysInSubdirectory() async throws {
    let (repository, child) = try await fixture()
    let store = WorkspaceStore(dataRoot: repository.appendingPathComponent(".private-data"))
    store.project = child
    store.workspace.root = child
    await store.workspace.refreshGit()
    let catalog = try await GitBranchService.snapshot(at: try XCTUnwrap(store.workspace.gitRoot))
    let changed = await store.changeBranch(.create(name: "nested-feature", startingAt: nil), snapshot: catalog)
    XCTAssertTrue(changed, store.branchChangeError ?? "Switch failed")
    XCTAssertEqual(store.workspace.gitBranch, "nested-feature")
    XCTAssertEqual(store.project, child)
    XCTAssertEqual(store.workspace.root, child)
    let remote = repository.deletingLastPathComponent().appendingPathComponent("nested-remote-\(UUID())")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: remote) }
    _ = try await GitReviewService.checked(["init", "-q", "--bare"], at: remote)
    _ = try await GitReviewService.checked(["remote", "add", "origin", remote.path], at: repository)
    let pushed = await store.workspace.push(remote: "origin", destination: "nested-feature", forceWithLease: false)
    XCTAssertTrue(pushed, store.workspace.error ?? "Push failed")
    let published = try await GitReviewService.checked(["rev-parse", "refs/heads/nested-feature"], at: remote)
    let local = try await GitReviewService.checked(["rev-parse", "HEAD"], at: repository)
    XCTAssertEqual(published, local)
    let recordedBranch = await store.branchForTaskHistory()
    XCTAssertEqual(recordedBranch, "nested-feature")
    XCTAssertEqual(store.workspace.root, child)
  }

  func testCommentsKeepTaskIdentityAndRepositoryRelativePathsIncludingLegacyDecode() async throws {
    let (repository, child) = try await fixture()
    let store = WorkspaceStore(dataRoot: repository.appendingPathComponent(".private-data"))
    store.project = child
    store.workspace.root = child
    await store.workspace.refreshGit()
    let task = WorkspaceTask(id: "nested-task", project: child.path, title: "Nested", runIDs: [])
    store.library.tasks = [task]
    let anchor = ReviewAnchor(project: child.path, path: "outside.txt", scope: "未暂存",
      revision: "working tree", fingerprint: "snapshot", oldLine: 1, newLine: 1,
      code: "changed", repository: repository.path)
    store.beginReviewComment(anchor, taskID: task.id)
    let comment = try XCTUnwrap(store.reviewComments(taskID: task.id).first)
    store.updateReviewComment(comment.id, text: "Check this sibling file", taskID: task.id)
    store.saveReviewComment(comment.id, taskID: task.id)
    let prompt = try store.promptWithReviewComments("Review this", comments: store.reviewComments(taskID: task.id), project: child.path)
    XCTAssertTrue(prompt.contains(repository.path))
    XCTAssertTrue(prompt.contains("outside.txt"))
    let reopened = try JSONDecoder().decode(ReviewAnchor.self, from: JSONEncoder().encode(anchor))
    XCTAssertEqual(reopened, anchor)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(anchor)) as? [String: Any])
    object.removeValue(forKey: "repository")
    let legacy = try JSONDecoder().decode(ReviewAnchor.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(legacy.repository)
    var wrong = anchor
    wrong.repository = child.path
    store.beginReviewComment(wrong, taskID: task.id)
    XCTAssertEqual(store.reviewComments(taskID: task.id).count, 1)
    _ = try await GitReviewService.checked(["init", "-q"], at: child)
    XCTAssertThrowsError(try store.promptWithReviewComments("Review this", comments: store.reviewComments(taskID: task.id), project: child.path))
  }

  func testModelReviewSnapshotIncludesSiblingDiffAndExplicitRepositoryPath() async throws {
    let (repository, child) = try await fixture()
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    let snapshot = try await workspace.modelReviewSnapshot(scope: .uncommitted)
    XCTAssertTrue(snapshot.diff.contains("App/inside.txt"))
    XCTAssertTrue(snapshot.diff.contains("outside.txt"))
    XCTAssertEqual(snapshot.repositoryRoot, repository.path)
    XCTAssertTrue(snapshot.modelPrompt.contains(repository.path))
    let restored = try JSONDecoder().decode(ModelCodeReviewSnapshot.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(restored, snapshot)
    let legacy = try JSONDecoder().decode(ModelCodeReviewSnapshot.self,
      from: Data(#"{"scope":{"uncommitted":{}},"diff":"old diff"}"#.utf8))
    XCTAssertNil(legacy.repositoryRoot)
    XCTAssertEqual(workspace.root, child)
  }

  func testNearestNestedRepositoryAndWorktreeGitFileResolveIndependently() async throws {
    let (repository, child) = try await fixture()
    _ = try await GitReviewService.checked(["init", "-q"], at: child)
    let inner = DeveloperWorkspace()
    inner.root = child
    await inner.refreshGit()
    XCTAssertEqual(inner.gitRepositoryRoot?.path, child.path)
    XCTAssertEqual(inner.visibleChanges.map(\.path), ["inside.txt"])
    let worktree = repository.deletingLastPathComponent().appendingPathComponent("nested-worktree-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: worktree) }
    _ = try await GitReviewService.checked(["worktree", "add", "-q", "-b", "worktree", worktree.path, "HEAD"], at: repository)
    let workspace = DeveloperWorkspace()
    workspace.root = GitBranchService.canonicalRoot(worktree.appendingPathComponent("App"))
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertEqual(workspace.gitRepositoryRoot?.path, GitBranchService.canonicalRoot(worktree).path)
    XCTAssertEqual(workspace.gitBranch, "worktree")
    XCTAssertTrue(workspace.canCommit)
  }

  func testNewNestedRepositoryInvalidatesOldMutationAuthorizationAndSnapshots() async throws {
    let (repository, child) = try await fixture()
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    let snapshot = try XCTUnwrap(workspace.batchSnapshot)
    let authorize = workspace.gitMutationAuthorization(at: try XCTUnwrap(workspace.gitRoot))
    _ = try await GitReviewService.checked(["init", "-q"], at: child)
    XCTAssertThrowsError(try authorize()) { XCTAssertTrue($0 is CancellationError) }
    await workspace.refreshGit()
    await workspace.stageAll(snapshot)
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertTrue(index.isEmpty)
    XCTAssertEqual(workspace.gitRepositoryRoot?.path, child.path)
  }

  func testMissingSubdirectoryAndBrokenNearestMetadataDoNotFallBackToParent() async throws {
    let (repository, child) = try await fixture()
    for path in [child.appendingPathComponent("missing"), child] {
      if path == child { try Data("broken metadata".utf8).write(to: child.appendingPathComponent(".git")) }
      let workspace = DeveloperWorkspace()
      workspace.root = path
      await workspace.refreshGit()
      XCTAssertFalse(workspace.gitAvailable)
      XCTAssertFalse(workspace.canCommit)
      XCTAssertNil(workspace.gitRepositoryRoot)
      XCTAssertNotNil(workspace.error)
    }
    let index = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertTrue(index.isEmpty)
  }

  func testTaskAndDetachedReviewsUseOwnerRepositoryAndCurrentReadOnlyPolicy() async throws {
    let (source, sourceChild) = try await fixture()
    let (main, mainChild) = try await fixture()
    let store = WorkspaceStore(dataRoot: main.appendingPathComponent(".private-data"))
    store.project = mainChild
    store.workspace.root = mainChild
    await store.workspace.refreshGit()
    let owner = WorkspaceTask(id: "owner", project: sourceChild.path, title: "Source", runIDs: [])
    store.library.tasks = [owner]
    let resources = TaskWindowResources()
    resources.prepare(owner.id, store: store)
    defer { resources.shutdown() }
    let workspace = try XCTUnwrap(resources.panels.tasks[owner.id]?.workspace)
    await Task.yield()
    await workspace.refreshFiles()
    await workspace.refreshGit()
    for _ in 0..<500 where workspace.gitRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(workspace.gitRoot?.path, source.path)
    await workspace.stage("outside.txt", undo: false)
    XCTAssertNil(workspace.error)
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: owner.id)
    defer { detached.shutdown() }
    await Task.yield()
    await detached.workspace.refreshFiles()
    await detached.workspace.refreshGit()
    for _ in 0..<500 where detached.workspace.gitRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(detached.workspace.gitRoot?.path, source.path)
    store.library.gitPreferences.readOnlyReview = true
    await detached.workspace.stage("App/inside.txt", undo: false)
    let onlySibling = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: source)
    XCTAssertEqual(onlySibling.trimmingCharacters(in: .newlines), "outside.txt")
    store.library.gitPreferences.readOnlyReview = false
    await detached.workspace.stage("App/inside.txt", undo: false)
    let ownerIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: source)
    XCTAssertEqual(Set(ownerIndex.split(separator: "\n").map(String.init)), ["App/inside.txt", "outside.txt"])
    let mainIndex = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: main)
    XCTAssertTrue(mainIndex.isEmpty)
    XCTAssertEqual(store.workspace.root, mainChild)
    XCTAssertEqual(store.project, mainChild)
  }

  func testBackgroundReviewDoesNotRewriteIndexForTimestampOnlyChanges() async throws {
    let (repository, child) = try await fixture()
    let file = child.appendingPathComponent("inside.txt")
    try Data("original\n".utf8).write(to: file)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
    try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(5)], ofItemAtPath: file.path)
    let index = repository.appendingPathComponent(".git/index")
    let previous = try Data(contentsOf: index)
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    XCTAssertEqual(try Data(contentsOf: index), previous, "Background inspection must not acquire optional index write locks")
    XCTAssertEqual(workspace.visibleChanges.map(\.path), ["outside.txt"])
  }

  func testInspectionPreservesExistingIndexLockAndMutationRespectsItUntilRetry() async throws {
    let (repository, child) = try await fixture()
    let lock = repository.appendingPathComponent(".git/index.lock")
    try Data("fixture lock".utf8).write(to: lock)
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertNil(workspace.error)
    await workspace.stage("outside.txt", undo: false)
    XCTAssertTrue(workspace.error?.contains("index.lock") == true)
    XCTAssertEqual(try String(contentsOf: lock), "fixture lock")
    let before = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertTrue(before.isEmpty)
    try FileManager.default.removeItem(at: lock)
    await workspace.stage("outside.txt", undo: false)
    XCTAssertNil(workspace.error)
    let after = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: repository)
    XCTAssertEqual(after.trimmingCharacters(in: .newlines), "outside.txt")
  }

  func testProjectFileListUsesRepositoryIgnoreRulesAndKeepsHiddenTrackedFilesInsideProject() async throws {
    let (repository, child) = try await fixture()
    try Data("hidden\n".utf8).write(to: child.appendingPathComponent(".hidden.txt"))
    try Data("ignored.txt\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
    _ = try await GitReviewService.checked(["add", "App/.hidden.txt", ".gitignore"], at: repository)
    _ = try await GitReviewService.checked(["commit", "-qm", "Hidden file"], at: repository)
    try Data("ignored\n".utf8).write(to: child.appendingPathComponent("ignored.txt"))
    let workspace = DeveloperWorkspace()
    workspace.root = child
    await workspace.refreshFiles()
    XCTAssertEqual(workspace.files, [".hidden.txt", "inside.txt"])
    XCTAssertThrowsError(try LocalWorkspaceService.read("../outside.txt", root: child))
    XCTAssertEqual(workspace.root, child)
  }

  func testRepositoryNameEndingInNewlineResolvesWithoutTrimmingFilename() async throws {
    let (repository, _) = try await fixture()
    let moved = repository.deletingLastPathComponent().appendingPathComponent(repository.lastPathComponent + "\n")
    try FileManager.default.moveItem(at: repository, to: moved)
    addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
    let root = GitBranchService.canonicalRoot(moved)
    let workspace = DeveloperWorkspace()
    workspace.root = GitBranchService.canonicalRoot(root.appendingPathComponent("App"))
    await workspace.refreshGit()
    XCTAssertTrue(workspace.gitAvailable)
    XCTAssertEqual(workspace.gitRepositoryRoot?.path, root.path)
    XCTAssertEqual(Set(workspace.visibleChanges.map(\.path)), ["App/inside.txt", "outside.txt"])
  }

  func testOldReviewFileRequestCannotOpenOrReplaceErrorsInNewRepository() async throws {
    let (source, _) = try await fixture()
    let (_, child) = try await fixture()
    let store = WorkspaceStore(dataRoot: child.appendingPathComponent(".private-data"))
    store.workspace.root = child
    await store.workspace.refreshGit()
    let request = store.workspace.fileOpenRequest
    store.workspace.fileOpenError = "Preserve current error"
    await store.openReviewFile("outside.txt", in: store.workspace, at: source)
    XCTAssertEqual(store.workspace.fileOpenRequest, request)
    XCTAssertEqual(store.workspace.fileOpenError, "Preserve current error")
    XCTAssertEqual(store.workspace.root, child)
  }
}
