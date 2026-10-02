import Foundation
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestWatchAutomationTests: XCTestCase {
  private let request = GitHubPullRequest(number: 17,
    url: "https://github.com/example/project/pull/17", title: "Fix build", isDraft: false,
    headRefName: "fix-build", baseRefName: "main", isCrossRepository: false)

  func testStartCreatesOnePersistedImmediateWatchWithConfiguredPrompt() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var preferences = store.library.gitPreferences
    preferences.autoMergeWatchedPullRequests = true
    preferences.pullRequestWatchInstructions = "Only fix failures introduced by this PR."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    let details = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in details }, runImmediately: false)
    XCTAssertTrue(started)
    let watch = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertEqual(store.automationPreferences.items.count, 1)
    XCTAssertTrue(watch.enabled)
    XCTAssertEqual(watch.selectedProjects, [root.path])
    XCTAssertEqual(watch.selectedExecution, .worktree)
    XCTAssertEqual(watch.customRule, "FREQ=MINUTELY;INTERVAL=10")
    XCTAssertGreaterThan(watch.nextRun, Date())
    XCTAssertTrue(watch.prompt.contains(request.url))
    XCTAssertTrue(watch.prompt.contains("matching-head-commit guard"))
    XCTAssertTrue(watch.prompt.contains(preferences.pullRequestWatchInstructions))
    XCTAssertEqual(try AutomationStorage.load(root: root).items.first?.id, watch.id)

    let restarted = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in details }, runImmediately: false)
    XCTAssertTrue(restarted)
    XCTAssertEqual(store.automationPreferences.items.count, 1)
    XCTAssertEqual(store.pullRequestWatch(for: request)?.id, watch.id)
  }

  func testPauseResumeAndClosedPullRequestStopBeforeStartingTask() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(started)
    let id = try XCTUnwrap(store.pullRequestWatch(for: request)?.id)
    store.pausePullRequestWatch(request)
    XCTAssertFalse(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    let resumed = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(resumed)
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)

    let merged = details(state: "MERGED")
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in merged })
    let completed = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertFalse(completed.enabled)
    XCTAssertNotNil(completed.completedAt)
    XCTAssertNil(completed.taskID)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertFalse(try XCTUnwrap(AutomationStorage.load(root: root).items.first).enabled)
  }

  func testReadFailureDelaysRetryWithoutCreatingTaskAndInvalidPRCannotStart() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(started)
    let id = try XCTUnwrap(store.pullRequestWatch(for: request)?.id)
    let before = Date()
    await store.runAutomation(id, scheduledAt: before, readWatchedPullRequest: { _, _ in
      throw AgentFailure(message: "offline")
    })
    let delayed = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertGreaterThanOrEqual(delayed.nextRun.timeIntervalSince(before), 300)
    XCTAssertTrue(delayed.enabled)
    XCTAssertNil(delayed.taskID)
    XCTAssertTrue(store.automationsError?.contains("offline") == true)

    let unknown = GitHubPullRequest(number: 18,
      url: "https://github.com/example/project/pull/18", title: "Other", isDraft: false,
      headRefName: "other", baseRefName: "main", isCrossRepository: false)
    let unknownStarted = await store.startPullRequestWatch(unknown, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertFalse(unknownStarted)
    XCTAssertEqual(store.automationPreferences.items.count, 1)
  }

  func testGreenPullRequestPausesWithoutMergeAndCustomInstructionsKeepWatchActive() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(started)
    let id = try XCTUnwrap(store.pullRequestWatch(for: request)?.id)
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in open })
    XCTAssertFalse(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    XCTAssertTrue(store.library.chatRuns.isEmpty)

    var preferences = store.library.gitPreferences
    preferences.pullRequestWatchInstructions = "Continue until this PR is merged."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    let resumed = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(resumed)
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in open })
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    XCTAssertTrue(store.automationsError?.contains("隔离工作树") == true)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
  }

  func testLegacyGitSettingsKeepWatchOffAndRequireValidWatchAutomation() throws {
    let legacy = try JSONDecoder().decode(GitPreferences.self,
      from: Data(#"{"branchPrefix":"codex/"}"#.utf8))
    XCTAssertFalse(legacy.autoMergeWatchedPullRequests)
    XCTAssertEqual(legacy.pullRequestWatchInstructions, "")
    XCTAssertTrue(PullRequestWatchPrompt.make(request, preferences: legacy)?.contains("Do not merge") == true)
    var invalid = ShipAutomation()
    invalid.name = "invalid"
    invalid.prompt = "watch"
    invalid.watchedPullRequest = request
    XCTAssertThrowsError(try AutomationStorage.validate(.init(items: [invalid])))
  }

  private func fixture() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.automationsLoaded = true
    store.library.tasks = [.init(id: "owner", project: root.path, title: "Source", runIDs: [])]
    store.library.taskPullRequests["owner"] = [request]
    return (store, root)
  }

  private func details(state: String) -> GitHubPRDetails {
    .init(number: request.number, url: request.url, title: request.title, body: nil,
      state: state, isDraft: false, headRefName: request.headRefName,
      baseRefName: request.baseRefName, reviewDecision: nil, mergeable: "MERGEABLE",
      statusCheckRollup: [], headRefOid: String(repeating: "a", count: 40), mergeStateStatus: "CLEAN")
  }
}
