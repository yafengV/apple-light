import XCTest
@testable import ShipiOS

@MainActor final class GitPullRequestOpenCommandTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, DeveloperWorkspace) {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "owner", project: root.path, title: "Owner", runIDs: []),
      .init(id: "other", project: root.appendingPathComponent("other").path, title: "Other", runIDs: [])]
    let workspace = DeveloperWorkspace(); workspace.root = root
    store.library.taskPullRequests["owner"] = [pr()]
    return (store, workspace)
  }
  private func pr(_ number: Int = 42, branch: String = "feature", state: String = "OPEN",
    url: String? = nil) -> GitHubPullRequest {
    .init(number: number, url: url ?? "https://github.com/sample/project/pull/\(number)", title: "PR \(number)",
      isDraft: false, headRefName: branch, baseRefName: "main", isCrossRepository: false, state: state)
  }
  private func request(_ workspace: DeveloperWorkspace, primary: Bool = true) -> GitWorkflowCommandRequest {
    .init(repository: .init(root: workspace.gitRoot, revision: workspace.reviewSnapshot,
      generation: workspace.generationForGitMutation, epoch: workspace.reviewRepositoryEpoch, taskID: "owner",
      suspended: workspace.gitBusy), primary: primary)
  }
  private func context(_ store: WorkspaceStore, _ workspace: DeveloperWorkspace,
    available: @escaping () -> Bool = { true },
    open: @escaping @MainActor (URL) async -> Bool = { _ in false }) -> GitWorkflowCommandContext {
    .init(store: store, workspace: workspace, taskID: "owner", request: request(workspace),
      available: available, openPullRequestLink: open)
  }
  private func settle(_ workspace: DeveloperWorkspace) async {
    await workspace.pullRequestLinkOpening.operation?.value
  }

  func testRecordedLinkOpensWithoutGitInReadonlyHistoricalAndBusyWorkspace() async throws {
    let (store, workspace) = try fixture()
    store.library.gitPreferences.readOnlyReview = true
    workspace.reviewScope = .commit; workspace.gitBusy = true; workspace.gitActionRunning = true
    workspace.gitAvailable = false; workspace.canCommit = false
    var opened: [URL] = []
    let command = context(store, workspace) { opened.append($0); return true }
    XCTAssertTrue(command.enabled("git.openPullRequest")); XCTAssertFalse(command.enabled("git.commit"))
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertEqual(opened, [pr().validatedURL!])
    XCTAssertFalse(workspace.showingPullRequest); XCTAssertFalse(workspace.showingCommitPush)
    XCTAssertEqual(store.library.taskPullRequests["owner"], [pr()])
  }

  func testMissingInvalidAndDifferentBranchLinksDoNotRegisterCommand() throws {
    let (store, workspace) = try fixture()
    workspace.gitBranch = "feature"
    let command = context(store, workspace)
    for records in [[], [pr(branch: "other")], [pr(url: "http://github.com/sample/project/pull/42")],
      [pr(url: "https://github.com/sample/project/pull/99")],
      [pr(url: "https://github.com/sample/project/pull/42?redirect=1")]] {
      store.library.taskPullRequests["owner"] = records
      XCTAssertFalse(command.visible("git.openPullRequest")); XCTAssertFalse(command.execute("git.openPullRequest"))
      XCTAssertFalse(CommandPaletteView.matchingCommands("", git: command).contains { $0.id == "git.openPullRequest" })
    }
  }

  func testStoredBranchAndClosedOrMergedLinkRemainOpenableOnDetachedHead() async throws {
    let (store, workspace) = try fixture()
    workspace.gitBranch = "detached HEAD"; store.library.tasks[0].gitBranch = "feature"
    store.library.taskPullRequests["owner"] = [pr(10, branch: "unrelated"), pr(42, state: "MERGED")]
    var opened: URL?
    let command = context(store, workspace) { opened = $0; return true }
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertEqual(opened, pr().validatedURL)
  }

  func testLivePrimaryPRTakesPrecedenceAndAttachedReviewKeepsOwningTaskLink() async throws {
    let (store, workspace) = try fixture(), req = request(workspace)
    let value = GitPullRequestReadiness(context: .init(plan: .init(root: workspace.root!, branch: "feature", commit: "commit",
      remote: "origin", destination: "refs/heads/feature", pushURL: "git@github.com:sample/project.git",
      trackingReference: "refs/remotes/origin/feature", expectedRemoteCommit: "commit", forceWithLease: false),
      repository: .init(owner: "sample", name: "project"), defaultBranch: "main", existing: pr(43), creationProblem: nil),
      hasLocalChanges: false, hasConflicts: false, commitsAhead: 0)
    await workspace.gitCommands.load(req) { _, _ in
      .init(canCommit: false, canPush: false, pullRequest: value, pullRequestError: nil)
    }
    var opened: [URL] = []
    var command = context(store, workspace) { opened.append($0); return true }
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    workspace.gitBusy = true
    await workspace.gitCommands.load(request(workspace)) { _, _ in XCTFail("Busy metadata must not be read"); throw CancellationError() }
    command = context(store, workspace) { opened.append($0); return true }
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    workspace.gitCommands.cancel(); XCTAssertNil(workspace.gitCommands.retainedPullRequest)
    workspace.gitBusy = false
    workspace.gitBranch = "attached-repository-branch"
    command = .init(store: store, workspace: workspace, taskID: "owner", request: request(workspace, primary: false),
      available: { true }, openPullRequestLink: { opened.append($0); return true })
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertEqual(opened, [pr(43).validatedURL!, pr(43).validatedURL!, pr(42).validatedURL!])
  }

  func testCurrentNamedBranchTakesPrecedenceOverStoredThreadBranchWithoutHosting() async throws {
    let (store, workspace) = try fixture()
    store.library.tasks[0].gitBranch = "feature"; workspace.gitBranch = "current"
    store.library.taskPullRequests["owner"] = [pr(42), pr(99, branch: "current")]
    var opened: URL?
    let command = context(store, workspace) { opened = $0; return true }
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertEqual(opened, pr(99).validatedURL)
  }

  func testOldOwnerDirectoryRemovalModalAndUnavailableWindowCannotExecute() throws {
    let (store, workspace) = try fixture()
    var owner: String? = "owner"
    var command = context(store, workspace); command.currentTaskID = { owner }
    owner = "other"; XCTAssertFalse(command.execute("git.openPullRequest"))
    owner = "owner"; workspace.showingManagedBranchSetup = true
    XCTAssertFalse(command.execute("git.openPullRequest")); workspace.showingManagedBranchSetup = false
    XCTAssertFalse(context(store, workspace, available: { false }).execute("git.openPullRequest"))
    store.library.tasks[0].project = workspace.root!.appendingPathComponent("moved").path
    XCTAssertFalse(command.execute("git.openPullRequest"))
    store.library.tasks.removeAll(); XCTAssertFalse(command.visible("git.openPullRequest"))
  }

  func testQueuedTaskReplacementAndWorkspaceResetCannotOpenOldLink() async throws {
    let (store, workspace) = try fixture()
    var opened = false
    var command = context(store, workspace) { _ in opened = true; return true }
    XCTAssertTrue(command.execute("git.openPullRequest"))
    store.library.taskPullRequests["owner"] = [pr(99)]
    await settle(workspace); XCTAssertFalse(opened)
    command = context(store, workspace) { _ in opened = true; return true }
    XCTAssertTrue(command.execute("git.openPullRequest"))
    let old = workspace.pullRequestLinkOpening.operation
    workspace.setProject(nil); await old?.value
    XCTAssertFalse(opened); XCTAssertFalse(workspace.pullRequestLinkOpening.opening)
    XCTAssertNil(workspace.pullRequestLinkOpening.error)
  }

  func testOpeningFailureIsScopedAndRetryAndAlternateShortcutWork() async throws {
    let (store, workspace) = try fixture()
    var accepts = false, count = 0
    let command = context(store, workspace) { _ in count += 1; return accepts }
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertNotNil(command.error); XCTAssertNil(store.workspace.pullRequestLinkOpening.error)
    XCTAssertFalse(workspace.pullRequestLinkOpening.opening)
    try store.shortcuts.set(ShortcutBinding("⌘⌥⇧P"), for: "git.openPullRequest")
    XCTAssertEqual(command.command(for: ShortcutBinding("⌘⌥⇧P"), shortcuts: store.shortcuts), "git.openPullRequest")
    accepts = true
    XCTAssertTrue(command.execute("git.openPullRequest")); await settle(workspace)
    XCTAssertEqual(count, 2); XCTAssertNil(workspace.pullRequestLinkOpening.error)
    XCTAssertTrue(CommandPaletteView.matchingCommands("在 GitHub", git: command).contains { $0.id == "git.openPullRequest" })
  }

  func testCancelledLateFailureDoesNotClearNewOpeningOrReportError() async throws {
    let (_, workspace) = try fixture(), opening = workspace.pullRequestLinkOpening
    var first: CheckedContinuation<Bool, Never>?, second: CheckedContinuation<Bool, Never>?
    XCTAssertTrue(opening.start(pr().validatedURL!, valid: { true }) { _ in
      await withCheckedContinuation { first = $0 }
    })
    let old = opening.operation
    while first == nil { await Task.yield() }
    opening.cancel()
    XCTAssertTrue(opening.start(pr(99).validatedURL!, valid: { true }) { _ in
      await withCheckedContinuation { second = $0 }
    })
    let new = opening.operation
    while second == nil { await Task.yield() }
    first?.resume(returning: false); await old?.value
    XCTAssertTrue(opening.opening); XCTAssertNil(opening.error)
    second?.resume(returning: true); await new?.value
    XCTAssertFalse(opening.opening); XCTAssertNil(opening.error)
  }

  func testLinkTargetPreferenceUsesTaskWindowCallbackOrExternalBrowserWithoutChangingMainSelection() async throws {
    let (store, _) = try fixture()
    var inside: [(URL, MessageWebLinkPresentation)] = [], outside: [URL] = []
    let url = pr().validatedURL!
    store.library.webLinkTarget = .inAppBrowser
    var success = await store.openTaskWebLink(url, taskID: "owner",
      openInApp: { inside.append(($0, $1)) }, openExternal: { outside.append($0); return true })
    XCTAssertTrue(success); XCTAssertEqual(inside.first?.0, url); XCTAssertEqual(inside.first?.1, .split)
    XCTAssertTrue(outside.isEmpty); XCTAssertNil(store.selection)
    store.library.webLinkTarget = .externalBrowser
    success = await store.openTaskWebLink(url, taskID: "owner",
      openInApp: { inside.append(($0, $1)) }, openExternal: { outside.append($0); return false })
    XCTAssertFalse(success); XCTAssertEqual(outside, [url]); XCTAssertEqual(inside.count, 1)
    store.library.tasks.removeAll()
    success = await store.openTaskWebLink(url, taskID: "owner", openExternal: { _ in XCTFail("Removed task"); return true })
    XCTAssertFalse(success)
  }
}
