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
    let details = details(state: "OPEN", head: "renamed-head")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in details }, runImmediately: false)
    XCTAssertTrue(started)
    let watch = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertEqual(store.automationPreferences.items.count, 1)
    XCTAssertTrue(watch.enabled)
    let fork = try XCTUnwrap(store.library.tasks.first { $0.id == watch.taskID })
    XCTAssertEqual(fork.forkOrigin?.taskID, "owner")
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertEqual(store.library.taskPullRequests[fork.id]?.first?.validatedURL,
      request.validatedURL)
    XCTAssertEqual(watch.selectedProjects, [root.path])
    XCTAssertEqual(watch.selectedExecution, .worktree)
    XCTAssertEqual(watch.customRule, "FREQ=MINUTELY;INTERVAL=10")
    XCTAssertGreaterThan(watch.nextRun, Date())
    XCTAssertTrue(watch.prompt.contains(request.url))
    XCTAssertTrue(watch.prompt.contains("Branch: renamed-head -> main"))
    XCTAssertEqual(watch.watchedPullRequest?.headRefName, "renamed-head")
    XCTAssertTrue(watch.prompt.contains("matching-head-commit guard"))
    XCTAssertTrue(watch.prompt.contains(preferences.pullRequestWatchInstructions))
    XCTAssertEqual(try AutomationStorage.load(root: root).items.first?.id, watch.id)

    let restarted = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in details }, runImmediately: false)
    XCTAssertTrue(restarted)
    XCTAssertEqual(store.automationPreferences.items.count, 1)
    XCTAssertEqual(store.pullRequestWatch(for: request)?.id, watch.id)
    XCTAssertEqual(store.pullRequestWatch(for: request)?.taskID, fork.id)
    XCTAssertEqual(store.library.tasks.count, 2)
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
    store.automationsError = nil
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in
      throw AgentFailure(message: "A paused watch must not read the PR")
    })
    XCTAssertNil(store.automationsError)
    let resumed = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(resumed)
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)

    let merged = details(state: "MERGED")
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in merged })
    let completed = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertFalse(completed.enabled)
    XCTAssertNil(completed.completedAt)
    XCTAssertNotNil(completed.pausedAt)
    XCTAssertNotNil(completed.taskID)
    XCTAssertEqual(store.library.chatRuns.count, 2)
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
    XCTAssertNotNil(delayed.taskID)
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
    XCTAssertEqual(store.library.chatRuns.count, 2)

    var preferences = store.library.gitPreferences
    preferences.pullRequestWatchInstructions = "Continue until this PR is merged."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    let resumed = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(resumed)
    preferences.pullRequestWatchInstructions = "Recheck all required checks before the next turn."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    await store.runAutomation(id, readWatchedPullRequest: { _, _ in open })
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).prompt
      .contains("Recheck all required checks before the next turn."))
    XCTAssertTrue(store.automationsError?.contains("隔离工作树") == true)
    XCTAssertEqual(store.library.chatRuns.count, 2)
  }

  func testLaterWatchOccurrenceKeepsPreviousTaskIdentity() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var preferences = store.library.gitPreferences
    preferences.autoMergeWatchedPullRequests = true
    XCTAssertTrue(store.saveGitPreferences(preferences))
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(started)
    var watch = try XCTUnwrap(store.pullRequestWatch(for: request))
    let retainedID = try XCTUnwrap(watch.taskID)
    watch.lastRunID = "earlier"
    XCTAssertTrue(store.saveAutomation(watch))
    let retainedIndex = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == retainedID })
    store.library.tasks[retainedIndex].runIDs.append("earlier")
    let earlier = AgentRun(id: "earlier", kind: "chat", project: root.path,
      status: "completed", createdAt: 0, updatedAt: 0,
      request: .object(["automation_id": .string(watch.id.uuidString)]),
      result: .object(["response": .string("Previous watch turn")]))
    store.library.chatRuns.append(earlier)

    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in open })
    let current = try XCTUnwrap(store.pullRequestWatch(for: request))
    XCTAssertEqual(current.taskID, retainedID)
    XCTAssertNil(current.activeOccurrenceAt)
    XCTAssertGreaterThan(current.nextRun, Date())
    XCTAssertNil(current.preparingTaskIDs?[root.path])
    XCTAssertEqual(store.library.tasks.filter { $0.id == retainedID }.count, 1)
    XCTAssertEqual(store.library.chatRuns.count, 2)
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

  func testFailedWatchSaveRollsBackForkAndEmptySourceCannotFork() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("automations.json"),
      withIntermediateDirectories: true)
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertFalse(started)
    XCTAssertEqual(store.library.tasks.map(\.id), ["owner"])
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertTrue(store.automationPreferences.items.isEmpty)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .tasks.map(\.id), ["owner"])

    try FileManager.default.removeItem(at: root.appendingPathComponent("automations.json"))
    store.library.tasks[0].runIDs = []
    let emptyStarted = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertFalse(emptyStarted)
    XCTAssertEqual(store.library.tasks.count, 1)
    XCTAssertTrue(store.automationsError?.contains("已结束的回合") == true)
  }

  func testSourceArchivedDuringPRRefreshCannotStartWatch() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in
        await MainActor.run { store.library.tasks[0].archived = true }
        return open
      }, runImmediately: false)
    XCTAssertFalse(started)
    XCTAssertEqual(store.library.tasks.count, 1)
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertTrue(store.automationPreferences.items.isEmpty)
  }

  func testDeletedRetainedTaskPausesWatchWithoutRecreatingIt() async throws {
    let (store, root) = fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let open = details(state: "OPEN")
    let started = await store.startPullRequestWatch(request, taskID: "owner", root: root,
      read: { _, _ in open }, runImmediately: false)
    XCTAssertTrue(started)
    let watch = try XCTUnwrap(store.pullRequestWatch(for: request))
    store.library.tasks.removeAll { $0.id == watch.taskID }
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      throw AgentFailure(message: "A deleted task must not refresh or run")
    })
    XCTAssertFalse(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    XCTAssertEqual(store.library.tasks.map(\.id), ["owner"])
    XCTAssertTrue(store.automationsError?.contains("监控已暂停") == true)
  }

  private func fixture() -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.automationsLoaded = true
    store.library.tasks = [.init(id: "owner", project: root.path,
      title: "Source", runIDs: ["source-run"])]
    store.library.chatRuns = [AgentRun(id: "source-run", kind: "chat", project: root.path,
      status: "completed", createdAt: 0, updatedAt: 0,
      request: .object(["kind": .string("chat")]),
      result: .object(["response": .string("Source conversation")]))]
    store.library.taskPullRequests["owner"] = [request]
    return (store, root)
  }

  private func details(state: String, head: String? = nil) -> GitHubPRDetails {
    .init(number: request.number, url: request.url, title: request.title, body: nil,
      state: state, isDraft: false, headRefName: head ?? request.headRefName,
      baseRefName: request.baseRefName, reviewDecision: nil, mergeable: "MERGEABLE",
      statusCheckRollup: [], headRefOid: String(repeating: "a", count: 40), mergeStateStatus: "CLEAN")
  }
}
