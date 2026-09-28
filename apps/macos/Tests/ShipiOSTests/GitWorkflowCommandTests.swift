import XCTest
@testable import ShipiOS

final class GitWorkflowCommandTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func git(_ args: [String], at root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func repository() async throws -> URL {
    let root = try directory()
    _ = try await git(["init", "-q", "-b", "main"], at: root)
    _ = try await git(["config", "user.name", "Test"], at: root)
    _ = try await git(["config", "user.email", "test@example.invalid"], at: root)
    try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "file.txt"], at: root)
    _ = try await git(["commit", "-qm", "base"], at: root)
    return root
  }
  private func readiness(_ root: URL, branch: String = "feature", changes: Bool = true,
    conflicts: Bool = false, ahead: Int = 0, problem: String? = nil,
    existing: GitHubPullRequest? = nil) -> GitPullRequestReadiness {
    .init(context: .init(plan: .init(root: root, branch: branch, commit: "commit", remote: "origin",
      destination: "refs/heads/feature", pushURL: "git@github.com:sample/project.git",
      trackingReference: "refs/remotes/origin/feature", expectedRemoteCommit: "commit", forceWithLease: false),
      repository: .init(owner: "sample", name: "project"), defaultBranch: "main", existing: existing,
      creationProblem: problem, publishedCommit: branch.isEmpty ? nil : "commit", allowsLocalPreparation: true),
      hasLocalChanges: changes, hasConflicts: conflicts, commitsAhead: ahead)
  }
  private func snapshot(_ root: URL, commit: Bool = true, push: Bool = false,
    branch: String = "feature", changes: Bool = true, ahead: Int = 0,
    problem: String? = nil) -> GitWorkflowCommandSnapshot {
    .init(canCommit: commit, canPush: push,
      pullRequest: readiness(root, branch: branch, changes: changes, ahead: ahead, problem: problem),
      pullRequestError: nil)
  }
  @MainActor private func request(_ workspace: DeveloperWorkspace, owner: String? = "owner",
    primary: Bool = true, suspended: Bool = false) -> GitWorkflowCommandRequest {
    .init(repository: .init(root: workspace.gitRoot, revision: workspace.reviewSnapshot,
      generation: workspace.generationForGitMutation, epoch: workspace.reviewRepositoryEpoch,
      taskID: owner, suspended: suspended), primary: primary)
  }
  @MainActor private func setup() throws -> (WorkspaceStore, DeveloperWorkspace) {
    let root = try directory()
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.library.tasks = [
      .init(id: "owner", project: root.path, title: "Owner", runIDs: []),
      .init(id: "other", project: root.path, title: "Other", runIDs: []),
    ]
    let workspace = DeveloperWorkspace()
    workspace.root = root; workspace.gitAvailable = true; workspace.canCommit = true
    return (store, workspace)
  }

  func testActualUntrackedChangesEnableCommitWithoutHostingOrRemote() async throws {
    let root = try await repository()
    try Data("new\n".utf8).write(to: root.appendingPathComponent("new.txt"))
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let before = try await git(["rev-parse", "HEAD"], at: root)
    let value = try await GitWorkflowCommandSnapshot.capture(at: root, primary: true) { _ in
      throw AgentFailure(message: "Hosting unavailable")
    }
    XCTAssertTrue(value.canCommit); XCTAssertFalse(value.canPush)
    XCTAssertNil(value.pullRequest); XCTAssertEqual(value.pullRequestError, "Hosting unavailable")
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    let after = try await git(["rev-parse", "HEAD"], at: root)
    XCTAssertEqual(before, after)
  }

  func testPushOnlyUsesTrackingAheadAndUnpublishedBranch() async throws {
    let root = try await repository()
    let base = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["remote", "add", "origin", root.appendingPathComponent("unused.git").path], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/main", base], at: root)
    var value = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in
      XCTFail("Attached repositories must not query hosting"); throw CancellationError()
    }
    XCTAssertFalse(value.canCommit); XCTAssertFalse(value.canPush)
    try Data("next\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "next"], at: root)
    value = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in throw CancellationError() }
    XCTAssertFalse(value.canCommit); XCTAssertTrue(value.canPush)
    _ = try await git(["switch", "-c", "unpublished"], at: root)
    value = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in throw CancellationError() }
    XCTAssertTrue(value.canPush)
  }

  func testDetachedEmptyAndDirtyCommitPathsDoNotPushUnnamedBranch() async throws {
    let root = try await repository()
    _ = try await git(["switch", "--detach"], at: root)
    let empty = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in throw CancellationError() }
    XCTAssertFalse(empty.canCommit); XCTAssertFalse(empty.canPush)
    try Data("dirty\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    let dirty = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in throw CancellationError() }
    XCTAssertTrue(dirty.canCommit); XCTAssertFalse(dirty.canPush)
  }

  func testConflictsDisableCommitEvenWithChanges() async throws {
    let root = try await repository()
    _ = try await git(["switch", "-c", "feature"], at: root)
    try Data("feature\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "feature"], at: root)
    _ = try await git(["switch", "main"], at: root)
    try Data("main\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "main"], at: root)
    _ = try await LocalWorkspaceService.git(["merge", "feature"], at: root)
    let value = try await GitWorkflowCommandSnapshot.capture(at: root, primary: false) { _ in throw CancellationError() }
    XCTAssertFalse(value.canCommit)
  }

  func testSourceChangeDuringHostingCheckRejectsOldMetadata() async throws {
    let root = try await repository()
    do {
      _ = try await GitWorkflowCommandSnapshot.capture(at: root, primary: true) { root in
        _ = try await self.git(["switch", "-c", "other"], at: root)
        return self.readiness(root)
      }
      XCTFail("Changed source must be rejected")
    } catch { XCTAssertTrue(error.localizedDescription.contains("改变")) }
  }

  @MainActor func testCommandCatalogSearchAndCustomBindingPersistence() throws {
    let file = try directory().appendingPathComponent("shortcuts.json")
    let shortcuts = ShortcutPreferences(file: file)
    for id in GitWorkflowCommandContext.ids {
      let command = try XCTUnwrap(DesktopCommand.all.first { $0.id == id })
      XCTAssertEqual(command.group, .project); XCTAssertTrue(command.defaultBindings.isEmpty)
      XCTAssertTrue(DesktopCommand.search(query: command.title).contains { $0.id == id })
    }
    try shortcuts.set(ShortcutBinding("⌘⌥⇧G"), for: "git.createDraftPullRequest")
    XCTAssertTrue(shortcuts.matches("git.createDraftPullRequest", ShortcutBinding("⌘⌥⇧G")))
    let restored = ShortcutPreferences(file: file)
    XCTAssertEqual(restored.bindings("git.createDraftPullRequest"), shortcuts.bindings("git.createDraftPullRequest"))
  }

  @MainActor func testDefaultBranchAndEmptyDetachedHidePRButCommitCanRemainEnabled() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    for value in [snapshot(workspace.root!, branch: "main"),
      snapshot(workspace.root!, branch: "", changes: false)] {
      await workspace.gitCommands.load(req) { _, _ in value }
      XCTAssertFalse(context.visible("git.createPullRequest"))
      XCTAssertFalse(context.execute("git.createDraftPullRequest"))
      XCTAssertTrue(context.enabled("git.commit"))
    }
  }

  @MainActor func testDetachedDirtyOrAheadAllowsSingleUseDraftOverride() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    store.library.gitPreferences.createDraftPullRequests = false
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    for value in [snapshot(workspace.root!, branch: ""),
      snapshot(workspace.root!, branch: "", changes: false, ahead: 1)] {
      await workspace.gitCommands.load(req) { _, _ in value }
      XCTAssertTrue(context.execute("git.createDraftPullRequest"))
      XCTAssertTrue(workspace.showingPullRequest); XCTAssertTrue(workspace.gitPresentationForceDraft)
      XCTAssertEqual(workspace.gitPresentationTaskID, "owner")
      XCTAssertFalse(store.library.gitPreferences.createDraftPullRequests)
      XCTAssertFalse(context.execute("git.commit"))
      workspace.showingPullRequest = false; workspace.clearGitPresentation()
      XCTAssertFalse(workspace.gitPresentationForceDraft)
      XCTAssertTrue(context.execute("git.createPullRequest"))
      XCTAssertFalse(workspace.gitPresentationForceDraft)
      workspace.showingPullRequest = false; workspace.clearGitPresentation()
    }
  }

  @MainActor func testExistingPRHiddenAndBlockedFeatureDisabled() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!, problem: "No hosting permission") }
    XCTAssertTrue(context.visible("git.createPullRequest")); XCTAssertFalse(context.enabled("git.createPullRequest"))
    let existing = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42", title: "PR", isDraft: true,
      headRefName: "feature", baseRefName: "main", isCrossRepository: false)
    await workspace.gitCommands.load(req) { _, _ in
      .init(canCommit: true, canPush: false, pullRequest: self.readiness(workspace.root!, existing: existing), pullRequestError: nil)
    }
    XCTAssertFalse(context.visible("git.createPullRequest")); XCTAssertTrue(context.enabled("git.commit"))
  }

  @MainActor func testOnlyOwningWindowPresentsAndOldMainOwnerCannotExecute() async throws {
    let (store, local) = try setup(), req = request(local, owner: "other")
    let value = snapshot(local.root!, commit: false, push: true)
    await local.gitCommands.load(req) { _, _ in value }
    var currentOwner: String? = "other"
    let context = GitWorkflowCommandContext(store: store, workspace: local, taskID: "other", request: req,
      available: { true }, currentTaskID: { currentOwner })
    XCTAssertTrue(context.execute("git.commit")); XCTAssertTrue(local.showingCommitPush)
    XCTAssertFalse(store.workspace.showingCommitPush); XCTAssertEqual(local.gitPresentationTaskID, "other")
    local.showingCommitPush = false; local.clearGitPresentation()
    currentOwner = "new"
    XCTAssertFalse(context.execute("git.createPullRequest")); XCTAssertFalse(local.showingPullRequest)
    XCTAssertFalse(store.commandEnabled("git.commit"))
  }

  @MainActor func testReadonlyHistoricalBusyAndStaleRepositoryPreventCommands() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!) }
    var available = true
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { available })
    XCTAssertTrue(context.enabled("git.commit"))
    available = false; XCTAssertFalse(context.execute("git.commit")); available = true
    store.library.gitPreferences.readOnlyReview = true; XCTAssertFalse(context.execute("git.createPullRequest"))
    store.library.gitPreferences.readOnlyReview = false
    workspace.gitBusy = true; XCTAssertFalse(context.execute("git.commit")); workspace.gitBusy = false
    workspace.gitRefreshing = true; XCTAssertFalse(context.execute("git.createDraftPullRequest")); workspace.gitRefreshing = false
    workspace.gitActionRunning = true; XCTAssertFalse(context.execute("git.commit")); workspace.gitActionRunning = false
    workspace.reviewScope = .lastTurn; XCTAssertFalse(context.execute("git.commit")); workspace.reviewScope = .unstaged
    workspace.reviewRepositoryEpoch = UUID(); XCTAssertFalse(context.execute("git.commit"))
  }

  @MainActor func testKeyboardBindingsResolveOnlyQualifiedOwnerAndBlockedContextsStayLocal() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    let file = try directory().appendingPathComponent("shortcuts.json")
    let shortcuts = ShortcutPreferences(file: file)
    let binding = ShortcutBinding("⌘⌥⇧G")
    try shortcuts.set(binding, for: "git.commit")
    var allowed = true
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner",
      request: req, available: { allowed })
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!, commit: false, push: true) }
    XCTAssertEqual(context.command(for: binding, shortcuts: shortcuts), "git.commit")
    allowed = false
    XCTAssertNil(context.command(for: binding, shortcuts: shortcuts))
    XCTAssertFalse(context.execute("git.commit")); XCTAssertFalse(store.workspace.showingCommitPush)
    allowed = true; workspace.reviewSnapshot = UUID()
    XCTAssertNil(context.command(for: binding, shortcuts: shortcuts))
  }

  @MainActor func testAttachedRepositoryHasCommitButNeverPrimaryPRCommands() async throws {
    let (store, workspace) = try setup(), req = request(workspace, primary: false)
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!) }
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    XCTAssertTrue(context.enabled("git.commit"))
    XCTAssertFalse(context.visible("git.createPullRequest")); XCTAssertFalse(context.execute("git.createDraftPullRequest"))
    XCTAssertFalse(workspace.showingPullRequest)
  }

  @MainActor func testProjectResetDismissesAndClearsOneShotPresentationAndMetadata() async throws {
    let (_, workspace) = try setup(), req = request(workspace)
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!) }
    workspace.presentGitOptions(taskID: "old", pullRequest: true, forceDraft: true)
    workspace.setProject(nil)
    XCTAssertFalse(workspace.showingPullRequest); XCTAssertFalse(workspace.showingCommitPush)
    XCTAssertNil(workspace.gitPresentationTaskID); XCTAssertFalse(workspace.gitPresentationForceDraft)
    XCTAssertNil(workspace.gitCommands.snapshot); XCTAssertFalse(workspace.gitCommands.loading)
  }

  @MainActor func testTaskDirectoryChangeOrDeletionCannotUsePreviousRepository() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!) }
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    XCTAssertTrue(context.enabled("git.createPullRequest"))
    store.library.tasks[0].project = try directory().path
    XCTAssertFalse(context.execute("git.createPullRequest")); XCTAssertFalse(workspace.showingPullRequest)
    store.library.tasks.removeFirst()
    XCTAssertFalse(context.execute("git.commit")); XCTAssertFalse(workspace.showingCommitPush)
  }

  @MainActor func testCancelledPendingReadCannotEnableCommandsAndRetrySucceeds() async throws {
    let (_, workspace) = try setup(), state = workspace.gitCommands, req = request(workspace)
    let value = snapshot(workspace.root!)
    var continuation: CheckedContinuation<GitWorkflowCommandSnapshot, Never>?
    let operation = Task { await state.load(req) { _, _ in
      await withCheckedContinuation { continuation = $0 }
    } }
    while continuation == nil { await Task.yield() }
    XCTAssertTrue(state.loading)
    operation.cancel(); continuation?.resume(returning: value); await operation.value
    XCTAssertFalse(state.loading); XCTAssertNil(state.snapshot)
    await state.load(req) { _, _ in value }
    XCTAssertNotNil(state.snapshot); XCTAssertFalse(state.loading)
  }

  @MainActor func testRenderedPaletteCatalogOnlyIncludesCurrentlyRegisteredGitActions() async throws {
    let (store, workspace) = try setup(), req = request(workspace)
    let context = GitWorkflowCommandContext(store: store, workspace: workspace, taskID: "owner", request: req, available: { true })
    func gitCommands() -> [String] {
      CommandPaletteView.matchingCommands("", git: context).map(\.id).filter(GitWorkflowCommandContext.owns)
    }
    XCTAssertTrue(gitCommands().isEmpty)
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!, problem: "Not authorized") }
    XCTAssertEqual(gitCommands(), ["git.commit"])
    await workspace.gitCommands.load(req) { _, _ in self.snapshot(workspace.root!) }
    XCTAssertEqual(gitCommands(), GitWorkflowCommandContext.ids.filter { $0 != "git.createBranch" })
    XCTAssertEqual(CommandPaletteView.matchingCommands("草稿 PR", git: context).map(\.id), ["git.createDraftPullRequest"])
    store.library.gitPreferences.readOnlyReview = true
    XCTAssertTrue(gitCommands().isEmpty)
    XCTAssertTrue(CommandPaletteView.matchingCommands("设置", git: context).contains { $0.id == "settings" })
    XCTAssertFalse(CommandPaletteView.matchingCommands("", git: nil).contains { GitWorkflowCommandContext.owns($0.id) })
  }

  @MainActor func testSuspendedReadFailureRetryAndCancellationEndLoading() async throws {
    let (_, workspace) = try setup(), state = workspace.gitCommands, req = request(workspace)
    await state.load(request(workspace, suspended: true)) { _, _ in XCTFail("Suspended read"); throw CancellationError() }
    XCTAssertFalse(state.loading); XCTAssertNil(state.snapshot)
    await state.load(req) { _, _ in throw AgentFailure(message: "Broken index") }
    XCTAssertEqual(state.error, "Broken index"); XCTAssertFalse(state.loading)
    await state.load(req) { _, _ in self.snapshot(workspace.root!) }
    XCTAssertNil(state.error); XCTAssertNotNil(state.snapshot)
    state.cancel(); XCTAssertNil(state.snapshot); XCTAssertFalse(state.loading)
  }

  @MainActor func testLateOldOwnerResultCannotReplaceNewOwnerMetadata() async throws {
    let (_, workspace) = try setup(), state = workspace.gitCommands
    let old = request(workspace, owner: "old"), new = request(workspace, owner: "new")
    let value = snapshot(workspace.root!)
    var continuation: CheckedContinuation<GitWorkflowCommandSnapshot, Never>?
    let previous = Task { await state.load(old) { _, _ in
      await withCheckedContinuation { continuation = $0 }
    } }
    while continuation == nil { await Task.yield() }
    await state.load(new) { _, _ in .init(canCommit: false, canPush: true, pullRequest: nil, pullRequestError: nil) }
    continuation?.resume(returning: value); await previous.value
    XCTAssertEqual(state.request, new); XCTAssertFalse(state.snapshot?.canCommit ?? true)
    XCTAssertTrue(state.snapshot?.canPush ?? false); XCTAssertFalse(state.loading)
  }
}
