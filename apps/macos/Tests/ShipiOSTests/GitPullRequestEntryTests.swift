import XCTest
@testable import ShipiOS

final class GitPullRequestEntryTests: XCTestCase {
  private func git(_ args: [String], at root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func fixture() async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], at: root)
    _ = try await git(["config", "user.name", "Test"], at: root)
    _ = try await git(["config", "user.email", "test@example.invalid"], at: root)
    try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "--all"], at: root)
    _ = try await git(["commit", "-qm", "base"], at: root)
    let base = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["switch", "-c", "feature/topic"], at: root)
    try Data("feature\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "feature"], at: root)
    let head = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["remote", "add", "origin", "git@github.com:sample/project.git"], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/main", base], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/feature/topic", head], at: root)
    _ = try await git(["branch", "--set-upstream-to=origin/feature/topic"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let cli = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: cli)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    try save(["base": base, "head": head], at: root)
    return (root, GitHubPRService(executable: cli))
  }
  private func save(_ state: [String: Any], at root: URL) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func existing(at root: URL) async throws {
    try save(["head": try await git(["rev-parse", "HEAD"], at: root),
      "base": try await git(["rev-parse", "main"], at: root),
      "pullRequests": [["number": 42, "url": "https://github.com/sample/project/pull/42",
        "title": "Existing PR", "isDraft": true, "headRefName": "feature/topic",
        "baseRefName": "main", "isCrossRepository": false]]], at: root)
  }
  private func request(_ root: URL, taskID: String? = nil) -> GitPullRequestEntryRequest {
    .init(root: root, revision: UUID(), generation: UUID(), epoch: UUID(), taskID: taskID)
  }
  private func readiness(root: URL = URL(fileURLWithPath: "/tmp/entry"), ahead: Int = 1) -> GitPullRequestReadiness {
    let plan = GitPushPlan(root: root, branch: "feature", commit: "commit", remote: "origin",
      destination: "refs/heads/feature", pushURL: "git@github.com:sample/project.git",
      trackingReference: "refs/remotes/origin/feature", expectedRemoteCommit: "commit", forceWithLease: false)
    return .init(context: .init(plan: plan, repository: .init(owner: "sample", name: "project"),
      defaultBranch: "main", existing: nil, creationProblem: nil, publishedCommit: "commit",
      allowsLocalPreparation: true), hasLocalChanges: false, hasConflicts: false, commitsAhead: ahead)
  }

  func testPublishedBranchAndDefaultBranchHaveDifferentCreationAvailability() async throws {
    let (root, service) = try await fixture()
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let feature = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertNil(feature.blockedReason(includeLocalChanges: true))
    XCTAssertNil(feature.blockedReason(includeLocalChanges: false))
    XCTAssertEqual(feature.commitsAhead, 1)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    _ = try await git(["switch", "main"], at: root)
    let main = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertNotNil(main.blockedReason(includeLocalChanges: true))
    XCTAssertNotNil(main.blockedReason(includeLocalChanges: false))
  }

  func testDetachedEmptyDirtyAndAheadStatesRespectLocalChangesSelection() async throws {
    let (root, service) = try await fixture()
    _ = try await git(["switch", "--detach", "main"], at: root)
    let empty = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertNotNil(empty.blockedReason(includeLocalChanges: true))
    XCTAssertNotNil(empty.blockedReason(includeLocalChanges: false))
    let head = try await git(["rev-parse", "HEAD"], at: root)
    try Data("untracked\n".utf8).write(to: root.appendingPathComponent("new.txt"))
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let dirty = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertTrue(dirty.hasLocalChanges)
    XCTAssertNil(dirty.blockedReason(includeLocalChanges: true))
    XCTAssertNotNil(dirty.blockedReason(includeLocalChanges: false))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    let after = try await git(["rev-parse", "HEAD"], at: root)
    XCTAssertEqual(after, head)
    _ = try await git(["switch", "--detach", "feature/topic"], at: root)
    let ahead = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertEqual(ahead.commitsAhead, 1)
    XCTAssertNil(ahead.blockedReason(includeLocalChanges: false))
  }

  func testUnpublishedNamedBranchDisablesUncheckedCreationAndSameBaseIsRejected() async throws {
    let (root, service) = try await fixture()
    _ = try await git(["update-ref", "-d", "refs/remotes/origin/feature/topic"], at: root)
    let value = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertNil(value.blockedReason(includeLocalChanges: true))
    XCTAssertNotNil(value.blockedReason(includeLocalChanges: false))
    let same = try await GitPullRequestReadiness.capture(at: root, base: "feature/topic", service: service)
    XCTAssertNotNil(same.blockedReason(includeLocalChanges: true))
  }

  func testRealConflictsBlockCommitPathButPublishedOnlyPathRemainsAvailable() async throws {
    let (root, service) = try await fixture()
    _ = try await git(["switch", "main"], at: root)
    try Data("other\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "other"], at: root)
    _ = try await git(["switch", "feature/topic"], at: root)
    let merge = try await LocalWorkspaceService.git(["merge", "main"], at: root)
    XCTAssertNotEqual(merge.status, 0)
    let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let value = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertTrue(value.hasConflicts)
    XCTAssertNotNil(value.blockedReason(includeLocalChanges: true))
    XCTAssertNil(value.blockedReason(includeLocalChanges: false))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
  }

  func testStagedChangeCancelledInWorktreeDoesNotEnableEmptyDetachedCommit() async throws {
    let (root, service) = try await fixture()
    _ = try await git(["switch", "--detach", "main"], at: root)
    try Data("staged\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "file.txt"], at: root)
    try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let value = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertFalse(value.hasLocalChanges)
    XCTAssertNotNil(value.blockedReason(includeLocalChanges: true))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
  }

  @MainActor func testBackgroundInspectionNeverLoadsOrResetsEditableDraft() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    draft.title = "Manual title"; draft.body = "Manual body"; draft.base = "release"
    draft.branchName = "manual/name"; draft.includeLocalChanges = false
    draft.reportError("Previous form error")
    let loader = GitPullRequestEntryLoader()
    await loader.load(request(root)) { try await draft.inspectEntry(at: $0, base: $1) }
    XCTAssertNotNil(loader.readiness)
    XCTAssertNil(loader.error)
    XCTAssertNil(draft.context)
    XCTAssertFalse(draft.loading)
    XCTAssertEqual(draft.title, "Manual title")
    XCTAssertEqual(draft.body, "Manual body")
    XCTAssertEqual(draft.base, "release")
    XCTAssertEqual(draft.branchName, "manual/name")
    XCTAssertFalse(draft.includeLocalChanges)
    XCTAssertEqual(draft.error, "Previous form error")
  }

  @MainActor func testOldRootAndTaskCompletionCannotReplaceCurrentEntry() async throws {
    let loader = GitPullRequestEntryLoader()
    var old: CheckedContinuation<GitPullRequestReadiness, Error>?
    let root = URL(fileURLWithPath: "/tmp/entry")
    let previous = request(root, taskID: "old"), current = request(root, taskID: "new")
    let first = Task { await loader.load(previous) { _, _ in
      try await withCheckedThrowingContinuation { old = $0 }
    } }
    for _ in 0..<1000 where old == nil { await Task.yield() }
    let pending = try XCTUnwrap(old)
    await loader.load(current) { _, _ in self.readiness(ahead: 2) }
    pending.resume(throwing: AgentFailure(message: "Old root failure"))
    await first.value
    XCTAssertEqual(loader.request, current)
    XCTAssertEqual(loader.readiness?.commitsAhead, 2)
    XCTAssertNil(loader.error)
    XCTAssertFalse(loader.loading)
  }

  @MainActor func testCancellationSuspensionAndRetryClearStaleResults() async throws {
    let loader = GitPullRequestEntryLoader(), root = URL(fileURLWithPath: "/tmp/entry")
    var continuation: CheckedContinuation<GitPullRequestReadiness, Error>?
    let req = request(root)
    let running = Task { await loader.load(req) { _, _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    } }
    for _ in 0..<1000 where continuation == nil { await Task.yield() }
    let pending = try XCTUnwrap(continuation)
    running.cancel()
    pending.resume(returning: readiness())
    await running.value
    XCTAssertNil(loader.readiness)
    XCTAssertFalse(loader.loading)
    await loader.load(req) { _, _ in throw AgentFailure(message: "Hosting unavailable") }
    XCTAssertEqual(loader.error, "Hosting unavailable")
    await loader.load(req) { _, _ in self.readiness() }
    XCTAssertNotNil(loader.readiness)
    XCTAssertNil(loader.error)
    var paused = req; paused.suspended = true
    await loader.load(paused) { _, _ in XCTFail("Busy repository must not be inspected"); return self.readiness() }
    XCTAssertNil(loader.readiness)
    XCTAssertFalse(loader.loading)
    await loader.load(req) { _, _ in self.readiness() }
    loader.cancel()
    XCTAssertNil(loader.readiness)
    XCTAssertFalse(loader.loading)
  }

  @MainActor func testExistingEntryOpensInReadOnlyHistoricalReviewAndRecordsOnlyOwner() async throws {
    let (root, service) = try await fixture()
    try await existing(at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/app-state"))
    store.libraryLoaded = true
    store.library.tasks = [WorkspaceTask(id: "owner", project: root.path, title: "Owner", runIDs: []),
      WorkspaceTask(id: "other", project: root.path, title: "Other", runIDs: [])]
    store.library.gitPreferences.readOnlyReview = true
    let workspace = DeveloperWorkspace()
    workspace.root = root; workspace.reviewScope = .commit
    store.bindGitReviewPolicy(to: workspace, taskID: "owner")
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    workspace.pullRequestDraft.title = "Keep title"
    workspace.pullRequestDraft.body = "Keep body"
    let loader = GitPullRequestEntryLoader()
    await loader.load(request(root, taskID: "owner")) { try await workspace.pullRequestDraft.inspectEntry(at: $0, base: $1) }
    XCTAssertNotNil(loader.readiness?.context.existing)
    var opened: [URL] = []
    await loader.openExisting(in: workspace, store: store, taskID: "other") { opened.append($0); return true }
    XCTAssertTrue(opened.isEmpty)
    await loader.openExisting(in: workspace, store: store, taskID: "owner") { opened.append($0); return true }
    XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/sample/project/pull/42"])
    XCTAssertNil(loader.error)
    XCTAssertEqual(store.library.taskPullRequests["owner"]?.count, 1)
    XCTAssertNil(store.library.taskPullRequests["other"])
    XCTAssertFalse(workspace.showingPullRequest)
    XCTAssertEqual(workspace.pullRequestDraft.title, "Keep title")
    XCTAssertEqual(workspace.pullRequestDraft.body, "Keep body")
  }

  @MainActor func testExistingEntryBrowserFailureAndMovedHeadNeverPublishOrResetForm() async throws {
    let (root, service) = try await fixture()
    try await existing(at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/app-state"))
    let workspace = DeveloperWorkspace(); workspace.root = root
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    workspace.pullRequestDraft.title = "Keep"
    let loader = GitPullRequestEntryLoader()
    await loader.load(request(root)) { try await workspace.pullRequestDraft.inspectEntry(at: $0, base: $1) }
    await loader.openExisting(in: workspace, store: store, taskID: nil) { _ in false }
    XCTAssertEqual(loader.error, "无法打开系统浏览器，请重试。")
    _ = try await git(["switch", "main"], at: root)
    var didOpen = false
    await loader.openExisting(in: workspace, store: store, taskID: nil) { _ in didOpen = true; return true }
    XCTAssertFalse(didOpen)
    XCTAssertNotNil(loader.error)
    XCTAssertEqual(workspace.pullRequestDraft.title, "Keep")
    XCTAssertTrue(store.library.taskPullRequests.isEmpty)
    XCTAssertFalse(workspace.showingPullRequest)
  }

  @MainActor func testWorkspaceSwitchDuringExistingOpenDiscardsOldAction() async throws {
    let (root, service) = try await fixture()
    try await existing(at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/app-state"))
    let workspace = DeveloperWorkspace(); workspace.root = root
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    let loader = GitPullRequestEntryLoader()
    await loader.load(request(root)) { try await workspace.pullRequestDraft.inspectEntry(at: $0, base: $1) }
    var didOpen = false
    let running = Task {
      await loader.openExisting(in: workspace, store: store, taskID: nil) { _ in didOpen = true; return true }
    }
    for _ in 0..<1000 where !loader.opening { await Task.yield() }
    XCTAssertTrue(loader.opening)
    workspace.setProject(nil)
    loader.cancel()
    await running.value
    XCTAssertFalse(didOpen)
    XCTAssertNil(loader.error)
    XCTAssertFalse(loader.opening)
    XCTAssertTrue(store.library.taskPullRequests.isEmpty)
  }

  @MainActor func testActualHostingAuthFailureHasRetryAndNoIndefiniteLoading() async throws {
    let (root, service) = try await fixture()
    let head = try await git(["rev-parse", "HEAD"], at: root)
    let base = try await git(["rev-parse", "main"], at: root)
    try save(["head": head, "base": base, "authFailure": true], at: root)
    let draft = GitHubPRDraft(service: service), loader = GitPullRequestEntryLoader()
    draft.title = "Keep manual title"
    let req = request(root)
    await loader.load(req) { try await draft.inspectEntry(at: $0, base: $1) }
    XCTAssertNotNil(loader.error)
    XCTAssertFalse(loader.loading)
    XCTAssertNil(loader.readiness)
    try save(["head": head, "base": base], at: root)
    await loader.load(req) { try await draft.inspectEntry(at: $0, base: $1) }
    XCTAssertNotNil(loader.readiness)
    XCTAssertNil(loader.error)
    XCTAssertFalse(loader.loading)
    XCTAssertEqual(draft.title, "Keep manual title")
  }

  @MainActor func testNewlyDiscoveredPRRequiresRefreshWithoutLosingManualForm() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root, allowUnpublished: true)
    let previous = try XCTUnwrap(draft.context)
    draft.title = "Keep title"; draft.body = "Keep body"; draft.includeLocalChanges = false
    try await existing(at: root)
    let changed = try await draft.inspectEntry(at: root)
    XCTAssertTrue(changed.requiresRefresh(comparedTo: previous))
    XCTAssertEqual(changed.blockedReason(includeLocalChanges: false, expectedContext: previous),
      "PR 来源或状态已改变，请重新检查。")
    XCTAssertNil(draft.existing)
    XCTAssertEqual(draft.title, "Keep title")
    await draft.load(at: root, allowUnpublished: true)
    let current = try XCTUnwrap(draft.context)
    let refreshed = try await draft.inspectEntry(at: root)
    XCTAssertFalse(refreshed.requiresRefresh(comparedTo: current))
    XCTAssertEqual(draft.existing?.number, 42)
    XCTAssertEqual(draft.title, "Keep title")
    XCTAssertEqual(draft.body, "Keep body")
    XCTAssertFalse(draft.includeLocalChanges)
  }

  func testSourceChangeNeedsExplicitRefreshEvenWhenNewStateCanCreate() async throws {
    let (root, service) = try await fixture()
    let previous = try await service.inspect(at: root, allowUnpublished: true)
    try Data("another commit\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "another"], at: root)
    let changed = try await GitPullRequestReadiness.capture(at: root, service: service)
    XCTAssertNil(changed.blockedReason(includeLocalChanges: true))
    XCTAssertTrue(changed.requiresRefresh(comparedTo: previous))
    XCTAssertNotNil(changed.blockedReason(includeLocalChanges: true, expectedContext: previous))
  }
}
