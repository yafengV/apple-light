import XCTest
@testable import ShipiOS

@MainActor final class GitManagedBranchSetupTests: XCTestCase {
  private struct Fixture {
    let source: URL
    let root: URL
    let store: WorkspaceStore
    let workspace: DeveloperWorkspace
    let taskID: String
  }
  private func git(_ args: [String], at root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func fixture(subdirectory: Bool = false) async throws -> Fixture {
    let parent = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent(UUID().uuidString)
    let source = parent.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    _ = try await git(["init", "-q", "-b", "main"], at: source)
    _ = try await git(["config", "user.name", "Test"], at: source)
    _ = try await git(["config", "user.email", "test@example.invalid"], at: source)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("app"), withIntermediateDirectories: true)
    try Data("base\n".utf8).write(to: source.appendingPathComponent("app/file.txt"))
    _ = try await git(["add", "app/file.txt"], at: source)
    _ = try await git(["commit", "-qm", "base"], at: source)
    let snapshot = try await GitBranchService.snapshot(at: source)
    var checkout = try await WorktreeService.plan(snapshot: snapshot, branch: nil, title: "Managed",
      parent: parent.appendingPathComponent("checkouts"))
    try await WorktreeService.createOrRecover(checkout)
    checkout.ready = true
    let root = URL(fileURLWithPath: checkout.path), owner = UUID().uuidString
    let project = subdirectory ? root.appendingPathComponent("app") : root
    let store = WorkspaceStore(dataRoot: parent.appendingPathComponent("state"))
    store.libraryLoaded = true
    store.library.tasks = [.init(id: owner, project: project.path, title: "Prepare branch", runIDs: ["historical"],
      codexThreadID: UUID().uuidString)]
    store.library.runBranches["historical"] = "old-history"
    store.library.managedWorktrees = [.init(taskID: owner, checkout: checkout)]
    try store.commitLibrary(store.library)
    let workspace = DeveloperWorkspace()
    workspace.root = project; workspace.gitRepositoryRoot = root
    workspace.gitAvailable = true; workspace.canCommit = true; workspace.gitBranch = "detached HEAD"
    store.bindGitReviewPolicy(to: workspace, taskID: owner)
    return Fixture(source: source, root: root, store: store, workspace: workspace, taskID: owner)
  }
  private func prepare(_ f: Fixture, name: String = "feature/prepared", next: GitManagedBranchNext? = nil) async throws {
    XCTAssertTrue(f.store.presentManagedBranchSetup(in: f.workspace, taskID: f.taskID, next: next))
    let request = try XCTUnwrap(f.workspace.managedBranchRequest)
    await f.workspace.managedBranchSetup.load(request, suggestion: name)
    await f.workspace.managedBranchSetup.validate()
    XCTAssertTrue(f.workspace.managedBranchSetup.canCreate)
  }
  private func hasBranch(_ name: String, at root: URL) async throws -> Bool {
    try await LocalWorkspaceService.git(["show-ref", "--verify", "--quiet", "refs/heads/" + name], at: root).status == 0
  }

  func testCreatePreservesStagedWorkingAndUntrackedChangesAndPersistsOwnMetadata() async throws {
    let f = try await fixture()
    try Data("staged\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    _ = try await git(["add", "app/file.txt"], at: f.root)
    try Data("working\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    try Data("untracked\n".utf8).write(to: f.root.appendingPathComponent("new.txt"))
    let staged = try await git(["diff", "--cached", "--binary"], at: f.root)
    let head = try await git(["rev-parse", "HEAD"], at: f.root)
    let tree = try await git(["rev-parse", "HEAD^{tree}"], at: f.root)
    let identity = f.store.library.tasks[0].codexThreadID
    try await prepare(f)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertTrue(success)
    let branch = try await git(["symbolic-ref", "--short", "HEAD"], at: f.root)
    let current = try await git(["rev-parse", "HEAD"], at: f.root)
    let currentStaged = try await git(["diff", "--cached", "--binary"], at: f.root)
    XCTAssertEqual(branch, "feature/prepared"); XCTAssertEqual(current, head); XCTAssertEqual(currentStaged, staged)
    XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("app/file.txt")), "working\n")
    XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("new.txt")), "untracked\n")
    let saved = try WorkspaceLibrary.load(from: f.store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.managedWorktrees[0].syncedBranch, .init(reference: "refs/heads/feature/prepared", tree: tree))
    XCTAssertEqual(saved.tasks[0].gitBranch, "feature/prepared"); XCTAssertEqual(saved.tasks[0].codexThreadID, identity)
    XCTAssertEqual(saved.runBranches["historical"], "old-history")
    let sourceBranch = try await git(["symbolic-ref", "--short", "HEAD"], at: f.source)
    XCTAssertEqual(sourceBranch, "main")
    XCTAssertFalse(f.workspace.showingPullRequest); XCTAssertFalse(f.workspace.showingCommitPush)
  }

  func testPRContinuationRetainsOwnerAndSingleUseDraftAndOnlyRunsAfterDismissal() async throws {
    let f = try await fixture()
    try await prepare(f, next: .pullRequest(forceDraft: true))
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertTrue(success); XCTAssertFalse(f.workspace.showingPullRequest)
    f.store.finishManagedBranchPresentation(in: f.workspace)
    XCTAssertTrue(f.workspace.showingPullRequest); XCTAssertTrue(f.workspace.gitPresentationForceDraft)
    XCTAssertEqual(f.workspace.gitPresentationTaskID, f.taskID)
    XCTAssertFalse(f.store.library.gitPreferences.createDraftPullRequests)
    XCTAssertFalse(f.store.workspace.showingPullRequest)
    f.store.finishManagedBranchPresentation(in: f.workspace)
    XCTAssertTrue(f.workspace.showingPullRequest)
  }

  func testCommitContinuationWaitsForSuccessfulCheckoutAndDismissal() async throws {
    let f = try await fixture()
    try Data("local\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    try await prepare(f, next: .commit)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertTrue(success); XCTAssertFalse(f.workspace.showingCommitPush)
    f.store.finishManagedBranchPresentation(in: f.workspace)
    XCTAssertTrue(f.workspace.showingCommitPush); XCTAssertEqual(f.workspace.gitPresentationTaskID, f.taskID)
    XCTAssertFalse(f.store.workspace.showingCommitPush); XCTAssertNil(f.workspace.managedBranchRequest)
    let staged = try await git(["diff", "--cached", "--name-only"], at: f.root)
    XCTAssertTrue(staged.isEmpty)
  }

  func testCancelDropsPendingContinuationAndDoesNotCreateBranch() async throws {
    let f = try await fixture()
    try await prepare(f, next: .commit)
    f.workspace.showingManagedBranchSetup = false
    f.store.finishManagedBranchPresentation(in: f.workspace)
    XCTAssertNil(f.workspace.managedBranchRequest); XCTAssertFalse(f.workspace.showingCommitPush)
    let exists = try await hasBranch("feature/prepared", at: f.root)
    XCTAssertFalse(exists); XCTAssertNil(f.store.library.managedWorktrees[0].syncedBranch)
  }

  func testNameValidationRejectsExistingAndRefNamespacesAndSupportsOneLocalPrefix() async throws {
    let f = try await fixture()
    for input in ["", "codex/", "-branch", "refs/remotes/origin/topic", "refs/tags/tag", "refs/heads/refs/heads/topic", "a..b", "main", "@{-1}"] {
      do { _ = try await GitManagedBranchPlan.validate(input, at: f.root); XCTFail(input) } catch {}
    }
    let normalized = try await GitManagedBranchPlan.validate("  refs/heads/feature/normalized  ", at: f.root)
    XCTAssertEqual(normalized, "feature/normalized")
    let literal = try await GitManagedBranchPlan.validate("refs/custom/topic", at: f.root)
    XCTAssertEqual(literal, "refs/custom/topic")
  }

  func testSourceCommitChangeBeforeCreateIsRejectedWithoutNewBranch() async throws {
    let f = try await fixture()
    try await prepare(f)
    try Data("new\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    _ = try await git(["commit", "-am", "external"], at: f.root)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success); XCTAssertNotNil(f.workspace.managedBranchSetup.error)
    let exists = try await hasBranch("feature/prepared", at: f.root)
    XCTAssertFalse(exists); XCTAssertNil(f.store.library.managedWorktrees[0].syncedBranch)
    XCTAssertFalse(f.workspace.managedBranchSetup.working); XCTAssertFalse(f.workspace.gitBusy)
  }

  func testReadonlyOrRemovedOwnerCannotCreateFromOpenModal() async throws {
    let f = try await fixture()
    try await prepare(f)
    f.store.library.gitPreferences.readOnlyReview = true
    var success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success)
    f.store.library.gitPreferences.readOnlyReview = false
    f.store.library.tasks.removeAll()
    success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success)
    let exists = try await hasBranch("feature/prepared", at: f.root)
    XCTAssertFalse(exists)
  }

  func testMetadataSaveFailureRetainsCreatedBranchAndDoesNotCheckoutOrContinue() async throws {
    let f = try await fixture()
    try await prepare(f, next: .commit)
    let file = f.store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success); XCTAssertTrue(f.workspace.showingManagedBranchSetup)
    XCTAssertTrue(f.workspace.managedBranchSetup.error?.contains("分支已创建") == true)
    let exists = try await hasBranch("feature/prepared", at: f.root)
    XCTAssertTrue(exists); XCTAssertNil(f.store.library.managedWorktrees[0].syncedBranch)
    let symbolic = try await LocalWorkspaceService.git(["symbolic-ref", "-q", "HEAD"], at: f.root)
    XCTAssertNotEqual(symbolic.status, 0); XCTAssertFalse(f.workspace.showingCommitPush)
  }

  func testCheckoutHookFailureKeepsBranchMetadataAndDoesNotStartPR() async throws {
    let f = try await fixture()
    try await prepare(f, next: .pullRequest(forceDraft: false))
    let common = try await WorktreeService.commonDirectory(at: f.root)
    let hook = common.appendingPathComponent("hooks/post-checkout")
    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success); XCTAssertNotNil(f.store.library.managedWorktrees[0].syncedBranch)
    XCTAssertNil(f.store.library.tasks[0].gitBranch); XCTAssertFalse(f.workspace.showingPullRequest)
    XCTAssertFalse(f.workspace.managedBranchSetup.working); XCTAssertFalse(f.workspace.gitBusy)
  }

  func testTaskSaveFailureAfterCheckoutReportsActualBranchWithoutContinuing() async throws {
    let f = try await fixture()
    try await prepare(f, next: .commit)
    let common = try await WorktreeService.commonDirectory(at: f.root)
    let hook = common.appendingPathComponent("hooks/post-checkout")
    let file = f.store.dataRoot.appendingPathComponent("workspace.json")
    let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data(("#!/bin/sh\nrm -f " + quoted + "\nmkdir " + quoted + "\n").utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertFalse(success)
    let branch = try await git(["symbolic-ref", "--short", "HEAD"], at: f.root)
    XCTAssertEqual(branch, "feature/prepared")
    XCTAssertTrue(f.workspace.managedBranchSetup.error?.contains("已创建并检出") == true)
    XCTAssertNotNil(f.store.library.managedWorktrees[0].syncedBranch)
    XCTAssertNil(f.store.library.tasks[0].gitBranch); XCTAssertFalse(f.workspace.showingCommitPush)
    XCTAssertFalse(f.workspace.gitBusy); XCTAssertFalse(f.workspace.managedBranchSetup.working)
  }

  func testWorkspaceResetDuringPreflightCannotAttachResultsToNewWorkspace() async throws {
    let f = try await fixture()
    try await prepare(f, next: .commit)
    let setup = f.workspace.managedBranchSetup
    let operation = Task { await setup.create(in: f.workspace, store: f.store) }
    while !setup.working { await Task.yield() }
    f.workspace.setProject(nil)
    let success = await operation.value
    XCTAssertFalse(success); XCTAssertNil(f.workspace.root); XCTAssertFalse(setup.working)
    XCTAssertFalse(f.workspace.showingCommitPush); XCTAssertNil(f.store.library.managedWorktrees[0].syncedBranch)
  }

  func testSharedCheckoutOnlyRecordsRequestedTaskBranchAndLegacyRecordsDecode() async throws {
    let f = try await fixture()
    let otherID = UUID().uuidString
    f.store.library.managedWorktrees[0].sharedTaskIDs = [otherID]
    f.store.library.tasks.append(.init(id: otherID, project: f.root.path, title: "Other", runIDs: [], gitBranch: "previous"))
    try await prepare(f)
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertTrue(success)
    XCTAssertEqual(f.store.library.tasks.first { $0.id == otherID }?.gitBranch, "previous")
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.store.library)) as! [String: Any]
    var tasks = value["tasks"] as! [[String: Any]], records = value["managedWorktrees"] as! [[String: Any]]
    for i in tasks.indices { tasks[i].removeValue(forKey: "gitBranch") }
    for i in records.indices { records[i].removeValue(forKey: "syncedBranch") }
    value["tasks"] = tasks; value["managedWorktrees"] = records
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONSerialization.data(withJSONObject: value))
    XCTAssertNil(legacy.tasks[0].gitBranch); XCTAssertNil(legacy.managedWorktrees[0].syncedBranch)
  }

  func testSubdirectoryTaskUsesItsManagedRepositoryAndStandaloneCommandStaysLocal() async throws {
    let f = try await fixture(subdirectory: true)
    let req = GitWorkflowCommandRequest(repository: .init(root: f.root, revision: f.workspace.reviewSnapshot,
      generation: f.workspace.generationForGitMutation, epoch: f.workspace.reviewRepositoryEpoch, taskID: f.taskID), primary: true)
    await f.workspace.gitCommands.load(req) { _, _ in
      .init(canCommit: false, canPush: false, pullRequest: nil, pullRequestError: nil)
    }
    let context = GitWorkflowCommandContext(store: f.store, workspace: f.workspace, taskID: f.taskID, request: req, available: { true })
    XCTAssertTrue(context.enabled("git.createBranch")); XCTAssertTrue(context.execute("git.createBranch"))
    XCTAssertTrue(f.workspace.showingManagedBranchSetup); XCTAssertFalse(f.store.workspace.showingManagedBranchSetup)
    let request = try XCTUnwrap(f.workspace.managedBranchRequest)
    await f.workspace.managedBranchSetup.load(request, suggestion: "feature/subdirectory")
    await f.workspace.managedBranchSetup.validate()
    let success = await f.workspace.managedBranchSetup.create(in: f.workspace, store: f.store)
    XCTAssertTrue(success); XCTAssertEqual(f.workspace.root?.lastPathComponent, "app")
  }

  func testManagedPushOnlyDefaultBranchPreparesBeforeCommitOptions() async throws {
    let f = try await fixture()
    _ = try await git(["switch", "-c", "source"], at: f.source)
    _ = try await git(["switch", "main"], at: f.root)
    let base = try await git(["rev-parse", "HEAD"], at: f.root)
    _ = try await git(["remote", "add", "origin", f.source.path], at: f.root)
    _ = try await git(["update-ref", "refs/remotes/origin/main", base], at: f.root)
    try Data("ahead\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    _ = try await git(["commit", "-am", "ahead"], at: f.root)
    let value = try await GitWorkflowCommandSnapshot.capture(at: f.root, primary: false) { _ in throw CancellationError() }
    XCTAssertFalse(value.canCommit); XCTAssertTrue(value.canPush); XCTAssertEqual(value.defaultBranch, "main")
    let req = GitWorkflowCommandRequest(repository: .init(root: f.root, revision: f.workspace.reviewSnapshot,
      generation: f.workspace.generationForGitMutation, epoch: f.workspace.reviewRepositoryEpoch, taskID: f.taskID), primary: true)
    await f.workspace.gitCommands.load(req) { _, _ in value }
    let context = GitWorkflowCommandContext(store: f.store, workspace: f.workspace, taskID: f.taskID, request: req, available: { true })
    XCTAssertTrue(context.execute("git.commit")); XCTAssertTrue(f.workspace.showingManagedBranchSetup)
    XCTAssertEqual(f.workspace.managedBranchRequest?.next, .commit); XCTAssertFalse(f.workspace.showingCommitPush)
  }

  func testDefaultManagedToolbarOffersStandaloneBranchWithoutHostingOrChanges() async throws {
    let f = try await fixture()
    let req = GitWorkflowCommandRequest(repository: .init(root: f.root, revision: f.workspace.reviewSnapshot,
      generation: f.workspace.generationForGitMutation, epoch: f.workspace.reviewRepositoryEpoch, taskID: f.taskID), primary: true)
    let detached = try await GitWorkflowCommandSnapshot.capture(at: f.root, primary: false) { _ in throw CancellationError() }
    await f.workspace.gitCommands.load(req) { _, _ in detached }
    XCTAssertFalse(f.store.showsManagedBranchToolbar(in: f.workspace, taskID: f.taskID))
    _ = try await git(["switch", "-c", "source"], at: f.source)
    _ = try await git(["switch", "main"], at: f.root)
    let named = try await GitWorkflowCommandSnapshot.capture(at: f.root, primary: true) { _ in
      throw AgentFailure(message: "No hosting service")
    }
    await f.workspace.gitCommands.load(req) { _, _ in named }
    XCTAssertFalse(named.canCommit); XCTAssertFalse(named.canPush)
    XCTAssertTrue(f.store.showsManagedBranchToolbar(in: f.workspace, taskID: f.taskID))
    let context = GitWorkflowCommandContext(store: f.store, workspace: f.workspace, taskID: f.taskID, request: req, available: { true })
    XCTAssertFalse(context.enabled("git.commit")); XCTAssertTrue(context.enabled("git.createBranch"))
    f.store.library.gitPreferences.readOnlyReview = true
    XCTAssertFalse(context.enabled("git.createBranch"))
    f.store.library.gitPreferences.readOnlyReview = false
    XCTAssertTrue(context.execute("git.createBranch")); XCTAssertNil(f.workspace.managedBranchRequest?.next)
    XCTAssertFalse(f.store.showsManagedBranchToolbar(in: f.workspace, taskID: "other"))
    f.workspace.setProject(nil)
    XCTAssertFalse(f.store.showsManagedBranchToolbar(in: f.workspace, taskID: f.taskID))
  }

  func testManagedDefaultBranchWithLocalChangesCommandOpensCommitDirectly() async throws {
    let f = try await fixture()
    _ = try await git(["switch", "-c", "source"], at: f.source)
    _ = try await git(["switch", "main"], at: f.root)
    try Data("dirty\n".utf8).write(to: f.root.appendingPathComponent("app/file.txt"))
    let value = try await GitWorkflowCommandSnapshot.capture(at: f.root, primary: false) { _ in throw CancellationError() }
    let req = GitWorkflowCommandRequest(repository: .init(root: f.root, revision: f.workspace.reviewSnapshot,
      generation: f.workspace.generationForGitMutation, epoch: f.workspace.reviewRepositoryEpoch, taskID: f.taskID), primary: true)
    await f.workspace.gitCommands.load(req) { _, _ in value }
    XCTAssertTrue(f.store.showsManagedBranchToolbar(in: f.workspace, taskID: f.taskID))
    let context = GitWorkflowCommandContext(store: f.store, workspace: f.workspace, taskID: f.taskID, request: req, available: { true })
    XCTAssertTrue(context.execute("git.commit")); XCTAssertTrue(f.workspace.showingCommitPush)
    XCTAssertFalse(f.workspace.showingManagedBranchSetup)
  }
}
