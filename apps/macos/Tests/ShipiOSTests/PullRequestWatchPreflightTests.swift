import Foundation
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestWatchPreflightTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL, ShipAutomation, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.libraryLoaded = true
    store.automationsLoaded = true
    var watch = ShipAutomation(name: "Watch", prompt: "Monitor")
    watch.project = root.path
    watch.taskID = UUID().uuidString
    watch.cadence = .custom
    watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
    watch.scheduleAnchor = .now
    watch.execution = .worktree
    watch.watchedPullRequest = .init(number: 42,
      url: "https://github.com/sample/project/pull/42", title: "Fix", isDraft: false,
      headRefName: "fix", baseRefName: "main", isCrossRepository: false)
    store.library.tasks = [.init(id: watch.taskID!, project: root.path, title: "Monitor", runIDs: ["history"])]
    store.library.chatRuns = [.init(id: "history", kind: "chat", project: root.path,
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["prompt": .string("Original thread")]),
      result: .object(["response": .string("Original answer")]))]
    store.library.taskPullRequests[watch.taskID!] = [watch.watchedPullRequest!]
    guard store.saveAutomation(watch) else { throw AgentFailure(message: store.automationsError ?? "Invalid fixture") }
    return (store, root, watch, GitHubPRService(executable: executable))
  }

  private func fail(_ message: String, status: Int = 1, at root: URL) throws {
    try JSONSerialization.data(withJSONObject: ["detailReadFailure": message,
      "detailReadExitCode": status]).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }

  func testCLIAuthenticationFailurePausesAndRecordsQuestionInRetainedThread() async throws {
    let (store, root, watch, service) = try await fixture()
    try fail("gh auth login is required", status: 4, at: root)
    let at = Date()
    await store.runAutomation(watch.id, scheduledAt: at, readWatchedPullRequest: {
      try await service.details(for: $0, at: $1)
    })
    let paused = try XCTUnwrap(AutomationStorage.load(root: store.dataRoot).items.first)
    XCTAssertFalse(paused.enabled)
    XCTAssertEqual(paused.pausedAt, at)
    XCTAssertEqual(paused.taskID, watch.taskID)
    XCTAssertEqual(store.library.tasks.count, 1)
    XCTAssertEqual(store.library.tasks[0].runIDs.count, 2)
    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.title, "PR 状态检查")
    XCTAssertEqual(run.request["conversation_kind"].text, "watch_preflight")
    XCTAssertEqual(run.status, "failed")
    XCTAssertNil(run.request["model"].text)
    XCTAssertTrue(run.result?["response"].text?.contains("希望使用哪个") == true)
    XCTAssertTrue(run.result?["response"].text?.contains(watch.watchedPullRequest!.url) == true)
    XCTAssertEqual(paused.lastRunID, run.id)
    XCTAssertTrue(paused.unresolvedRunIDs.contains(run.id))
    XCTAssertTrue(store.library.unreadTasks.contains(watch.taskID!))
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      .chatRuns.last?.id, run.id)
    let notice = try XCTUnwrap(store.notices.items.first)
    XCTAssertEqual(notice.taskID, watch.taskID)
    XCTAssertEqual(notice.watchAutomationID, watch.id)
    await store.runDueAutomations(now: at.addingTimeInterval(3600))
    XCTAssertEqual(store.library.chatRuns.count, 2)
    store.setAutomationEnabled(true, id: watch.id)
    XCTAssertEqual(store.automationPreferences.items[0].taskID, watch.taskID)
    XCTAssertEqual(store.library.tasks[0].runIDs.count, 2)
    XCTAssertNil(store.automationPreferences.items[0].pausedAt)
  }

  func testMissingCLIAndPermissionDenialPauseBeforeModelOrWorktree() async throws {
    for blocked in [GitHubCLIError.Blocker.missingCLI, .access] {
      let (store, root, watch, service) = try await fixture()
      let reader: GitHubPRService
      if blocked == .missingCLI {
        reader = GitHubPRService(executable: root.appendingPathComponent("missing-cli"))
      } else {
        reader = service
        try fail("GraphQL: Resource not accessible by personal access token", at: root)
      }
      await store.runAutomation(watch.id, readWatchedPullRequest: { try await reader.details(for: $0, at: $1) })
      XCTAssertFalse(store.automationPreferences.items[0].enabled)
      XCTAssertEqual(store.automationPreferences.items[0].pauseReason, blocked.reason)
      XCTAssertTrue(store.library.chatRuns.last?.result?["response"].text?.contains(blocked.question) == true)
      XCTAssertTrue(store.library.managedWorktrees.isEmpty)
      XCTAssertNil(store.modelTask)
    }
  }

  func testNetworkRateLimitAndUnknownFailuresRetryWithoutPausing() async throws {
    for message in ["HTTP 403: API rate limit exceeded", "HTTP 429: Retry-After: 60",
      "HTTP 503: Service unavailable", "dial tcp: network is unreachable", "Unexpected response"] {
      let (store, root, watch, service) = try await fixture()
      try fail(message, at: root)
      let at = Date()
      await store.runAutomation(watch.id, scheduledAt: at,
        readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
      let current = try XCTUnwrap(AutomationStorage.load(root: store.dataRoot).items.first)
      XCTAssertTrue(current.enabled, message)
      XCTAssertNil(current.pausedAt)
      XCTAssertEqual(current.nextRun.timeIntervalSince(at), 300, accuracy: 0.001)
      XCTAssertEqual(store.library.chatRuns.count, 1)
    }
  }

  func testCancellationAndPauseDuringReadCannotRecordOrReschedule() async throws {
    let (store, _, watch, _) = try await fixture()
    let before = store.automationPreferences.items[0].nextRun
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in throw CancellationError() })
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertEqual(store.automationPreferences.items[0].nextRun, before)
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      await MainActor.run { store.setAutomationEnabled(false, id: watch.id) }
      throw GitHubCLIError(status: 4, output: "Login required")
    })
    XCTAssertFalse(store.automationPreferences.items[0].enabled)
    XCTAssertEqual(store.automationPreferences.items[0].nextRun, before)
    XCTAssertEqual(store.library.chatRuns.count, 1)
  }

  func testFailedPauseSaveDoesNotClaimPauseOrAppendConversation() async throws {
    let (store, _, watch, _) = try await fixture()
    let file = store.dataRoot.appendingPathComponent("automations.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      throw GitHubCLIError(status: 4, output: "Authentication required")
    })
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertNotNil(store.automationsError)
    XCTAssertEqual(store.notices.items.first?.level, .error)
  }

  func testChangedMonitorTaskIgnoresLateAuthenticationFailure() async throws {
    let (store, _, watch, _) = try await fixture()
    let replacement = UUID().uuidString
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      await MainActor.run {
        store.library.tasks.append(.init(id: replacement, project: watch.project,
          title: "Replacement", runIDs: []))
        var changed = watch
        changed.taskID = replacement
        XCTAssertTrue(store.saveAutomation(changed))
      }
      throw GitHubCLIError(status: 4, output: "Authentication required")
    })
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertEqual(store.automationPreferences.items[0].taskID, replacement)
    XCTAssertNil(store.automationPreferences.items[0].pausedAt)
    XCTAssertEqual(store.library.chatRuns.count, 1)
  }

  func testBlockerPreservesEarlierUnreviewedResult() async throws {
    let (store, _, watch, _) = try await fixture()
    var previous = watch
    previous.lastRunID = "history"
    previous.reviewedRunID = nil
    previous.pendingRunIDs = nil
    XCTAssertTrue(store.saveAutomation(previous))
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      throw GitHubCLIError(status: 4, output: "Authentication required")
    })
    let paused = try XCTUnwrap(AutomationStorage.load(root: store.dataRoot).items.first)
    XCTAssertEqual(paused.unresolvedRunIDs, ["history", store.library.chatRuns.last!.id])
  }

  func testRecordSaveFailureKeepsSchedulePausedAndReportsIncompleteRecord() async throws {
    let (store, _, watch, _) = try await fixture()
    try FileManager.default.createDirectory(at: store.dataRoot.appendingPathComponent("workspace.json"),
      withIntermediateDirectories: false)
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      throw GitHubCLIError(status: 4, output: "Authentication required")
    })
    XCTAssertFalse(try AutomationStorage.load(root: store.dataRoot).items[0].enabled)
    XCTAssertEqual(store.library.chatRuns.count, 1)
    XCTAssertTrue(store.automationsError?.contains("阻塞记录保存失败") == true)
    XCTAssertEqual(store.notices.items.first?.level, .error)
  }

  func testTypedClassificationDoesNotPauseUnknownErrorsOrRetainCredentialsInReport() async throws {
    XCTAssertNil(GitHubCLIError(status: 2, output: "gh auth login cancelled").blocker)
    XCTAssertEqual(GitHubCLIError(status: 1, output: "HTTP 401: Bad credentials").blocker, .authentication)
    XCTAssertEqual(GitHubCLIError(status: 1, output: "HTTP 403: Forbidden").blocker, .access)
    let (store, _, watch, _) = try await fixture()
    await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
      throw GitHubCLIError(status: 4, output: "Token: ghp_private_fixture_value")
    })
    let saved = try String(contentsOf: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertFalse(saved.contains("ghp_private_fixture_value"))
    XCTAssertTrue(saved.contains("watch_preflight"))
  }
}
