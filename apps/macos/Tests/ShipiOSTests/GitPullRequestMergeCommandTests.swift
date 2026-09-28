import XCTest
@testable import ShipiOS

@MainActor final class GitPullRequestMergeCommandTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, DeveloperWorkspace) {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state")); store.libraryLoaded = true
    store.library.tasks = [.init(id: "owner", project: root.path, title: "Owner", runIDs: []),
      .init(id: "other", project: root.path, title: "Other", runIDs: [])]
    store.library.taskPullRequests["owner"] = [pr()]
    let workspace = DeveloperWorkspace(); workspace.root = root
    return (store, workspace)
  }
  private func pr(state: String = "OPEN", draft: Bool = false) -> GitHubPullRequest {
    .init(number: 42, url: "https://github.com/sample/project/pull/42", title: "Feature",
      isDraft: draft, headRefName: "feature", baseRefName: "main", isCrossRepository: false, state: state)
  }
  private func snapshot(state: String = "OPEN", author: Bool = true, draft: Bool = false,
    auto: Bool = false, request: GitHubPullRequest? = nil) throws -> GitHubPRMergeSnapshot {
    let original = request ?? pr()
    let details = GitHubPRDetails(number: original.number, url: original.url, title: "Feature", body: nil, state: state,
      isDraft: draft, headRefName: "feature", baseRefName: "main", reviewDecision: nil,
      mergeable: "MERGEABLE", statusCheckRollup: [], headRefOid: String(repeating: "1", count: 40), mergeStateStatus: "CLEAN")
    return .init(details: details, repository: try GitHubRepository.parse("https://github.com/sample/project"),
      isAuthor: author, allowedMethods: [.merge, .squash], isAutoMergeEnabled: auto)
  }
  private func context(_ store: WorkspaceStore, _ workspace: DeveloperWorkspace,
    available: @escaping () -> Bool = { true }, selected: (() -> GitHubPullRequest?)? = nil, active: @escaping () -> [String] = { [] },
    open: @escaping @MainActor (GitHubPullRequest, Bool) async -> Bool = { _, _ in false }) -> GitWorkflowCommandContext {
    let request = GitWorkflowCommandRequest(repository: .init(root: workspace.gitRoot,
      revision: workspace.reviewSnapshot, generation: workspace.generationForGitMutation,
      epoch: workspace.reviewRepositoryEpoch, taskID: "owner", suspended: workspace.gitBusy), primary: true)
    return .init(store: store, workspace: workspace, taskID: "owner", request: request,
      available: available, selectedPullRequest: selected, activePullRequestURLs: active, openPullRequestDetails: open)
  }
  private func load(_ context: GitWorkflowCommandContext, _ value: GitHubPRMergeSnapshot) async {
    await context.workspace.pullRequestMergeCommand.load(context.mergeRequest) { _, _ in value }
  }

  func testOnlyVerifiedAuthorMetadataRegistersMergeCommand() async throws {
    let (store, workspace) = try fixture(), command = context(store, workspace)
    XCTAssertFalse(command.visible("git.mergePullRequest"))
    await load(command, try snapshot(author: false)); XCTAssertFalse(command.visible("git.mergePullRequest"))
    await load(command, try snapshot()); XCTAssertTrue(command.enabled("git.mergePullRequest"))
    XCTAssertEqual(CommandPaletteView.matchingCommands("合并 PR", git: command).map(\.id), ["git.mergePullRequest"])
    for value in [try snapshot(state: "MERGED"), try snapshot(draft: true)] {
      await load(command, value); XCTAssertFalse(command.visible("git.mergePullRequest"))
    }
  }

  func testActivePRHeaderUsesOpenNonAutoQualificationWithoutBlockingInactiveDetailEntry() async throws {
    let (store, workspace) = try fixture(); var active: [String] = []
    let command = context(store, workspace, active: { active })
    for value in [try snapshot(state: "CLOSED"), try snapshot(auto: true)] {
      await load(command, value); XCTAssertTrue(command.enabled("git.mergePullRequest"))
      active = [pr().url]; XCTAssertFalse(command.enabled("git.mergePullRequest"))
      active = []
    }
    await load(command, try snapshot()); active = [pr().url]
    XCTAssertTrue(command.enabled("git.mergePullRequest"))
  }

  func testExecutionUsesOwningWindowAndOnlyRequestsConfirmation() async throws {
    let (store, workspace) = try fixture(); store.selection = "other"; store.draft = "Main draft"
    var calls: [(GitHubPullRequest, Bool)] = []
    let command = context(store, workspace, open: { calls.append(($0, $1)); return true })
    await load(command, try snapshot())
    XCTAssertTrue(command.execute("git.mergePullRequest")); XCTAssertFalse(command.execute("git.mergePullRequest"))
    await workspace.pullRequestLinkOpening.operation?.value
    XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.0, pr()); XCTAssertEqual(calls.first?.1, true)
    XCTAssertEqual(store.selection, "other"); XCTAssertEqual(store.draft, "Main draft")
    XCTAssertFalse(workspace.showingPullRequest); XCTAssertFalse(workspace.showingCommitPush)
  }

  func testReadonlyModalAvailabilityAndGlobalActionLockPreventExecution() async throws {
    let (store, workspace) = try fixture(); var available = true
    let command = context(store, workspace, available: { available }); await load(command, try snapshot())
    store.library.gitPreferences.readOnlyReview = true; XCTAssertFalse(command.execute("git.mergePullRequest"))
    store.library.gitPreferences.readOnlyReview = false; workspace.showingCommitPush = true
    XCTAssertFalse(command.enabled("git.mergePullRequest")); workspace.showingCommitPush = false
    available = false; XCTAssertFalse(command.enabled("git.mergePullRequest")); available = true
    let coordinator = GitHubPRActionCoordinator.shared
    let lock = UUID(); XCTAssertTrue(coordinator.begin(pr().url, token: lock))
    defer { coordinator.end(pr().url, token: lock) }
    XCTAssertFalse(command.enabled("git.mergePullRequest"))
  }

  func testChangedTaskPRRepositoryAndRevisionRejectStaleCommand() async throws {
    let (store, workspace) = try fixture(), command = context(store, workspace); await load(command, try snapshot())
    workspace.reviewSnapshot = UUID(); XCTAssertFalse(command.execute("git.mergePullRequest"))
    let fresh = context(store, workspace); await load(fresh, try snapshot())
    store.library.tasks[0].project += "/moved"; XCTAssertFalse(fresh.execute("git.mergePullRequest"))
    store.library.tasks[0].project = workspace.root!.path; store.library.taskPullRequests["owner"] = []
    XCTAssertFalse(fresh.visible("git.mergePullRequest")); XCTAssertFalse(fresh.execute("git.mergePullRequest"))
  }

  func testQueuedReadonlyChangeCancelsBeforeOpeningDetails() async throws {
    let (store, workspace) = try fixture(); var opened = false
    let command = context(store, workspace, open: { _, _ in opened = true; return true })
    await load(command, try snapshot()); XCTAssertTrue(command.execute("git.mergePullRequest"))
    store.library.gitPreferences.readOnlyReview = true
    await workspace.pullRequestLinkOpening.operation?.value
    XCTAssertFalse(opened); XCTAssertFalse(workspace.pullRequestLinkOpening.opening)
  }

  func testSelectedPRUsesItsOwnRecordRatherThanCurrentBranchOrMainWindow() async throws {
    let (store, workspace) = try fixture()
    let selected = GitHubPullRequest(number: 99, url: "https://github.com/sample/project/pull/99", title: "Other branch",
      isDraft: false, headRefName: "other", baseRefName: "main", isCrossRepository: false, state: "OPEN")
    store.library.taskPullRequests["owner"]?.append(selected)
    workspace.gitBranch = "feature"; store.selection = "other"
    let command = context(store, workspace, selected: { selected }, active: { [selected.url] })
    XCTAssertEqual(command.linkedPullRequest, selected); XCTAssertEqual(command.mergeRequest?.pullRequest, selected)
    await load(command, try snapshot(request: selected)); XCTAssertTrue(command.enabled("git.mergePullRequest"))
    XCTAssertEqual(store.selection, "other")
  }

  func testMetadataFailureClearAndLateCompletionCannotReviveCancelledOrNewRequest() async throws {
    let (store, workspace) = try fixture(), command = context(store, workspace)
    let request = try XCTUnwrap(command.mergeRequest), state = workspace.pullRequestMergeCommand
    await load(command, try snapshot())
    await state.load(request) { _, _ in throw NSError(domain: "Fixture", code: 1) }
    XCTAssertNil(state.snapshot); XCTAssertNotNil(state.error); XCTAssertFalse(command.visible("git.mergePullRequest"))
    var continuation: CheckedContinuation<GitHubPRMergeSnapshot, Error>?
    let operation = Task { await state.load(request) { _, _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    } }
    while continuation == nil { await Task.yield() }
    state.cancel(); continuation?.resume(returning: try snapshot()); await operation.value
    XCTAssertNil(state.request); XCTAssertNil(state.snapshot); XCTAssertFalse(state.loading)
    let old = Task { await state.load(request) { _, _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    } }
    continuation = nil
    while continuation == nil { await Task.yield() }
    await state.load(nil); continuation?.resume(returning: try snapshot()); await old.value
    XCTAssertNil(state.snapshot); XCTAssertNil(state.error)
  }
}
