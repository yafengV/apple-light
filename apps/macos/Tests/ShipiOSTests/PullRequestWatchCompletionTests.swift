import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestWatchCompletionTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42,
    url: "https://github.com/sample/project/pull/42", title: "Fix", isDraft: false,
    headRefName: "fix", baseRefName: "main", isCrossRepository: false)

  private func fixture() async throws -> (WorkspaceStore, URL, ShipAutomation, GitHubPRService) {
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(["init", "-q"], at: root)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: fixture, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try save(state: "OPEN", at: root)
    let service = GitHubPRService(executable: executable)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true; store.automationsLoaded = true
    store.project = root; store.workspace.setProject(root)
    store.library.tasks = [.init(id: "source", project: root.path, title: "Source", runIDs: ["source-run"])]
    store.library.chatRuns = [.init(id: "source-run", kind: "chat", project: root.path,
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["prompt": .string("Original request")]),
      result: .object(["response": .string("Original answer")]))]
    store.library.taskPullRequests["source"] = [request]
    store.selection = "source"; store.draft = "Source draft"
    let started = await store.startPullRequestWatch(request, taskID: "source", root: root,
      read: { try await service.details(for: $0, at: $1) }, runImmediately: false)
    guard started, let watch = store.pullRequestWatch(for: request) else {
      throw AgentFailure(message: store.automationsError ?? "Fixture could not start")
    }
    addTeardownBlock { @MainActor in
      store.taskWindowResources.allObjects.forEach { $0.shutdown() }
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, root, watch, service)
  }

  private func save(state: String, at root: URL, extra: [String: Any] = [:]) throws {
    var value: [String: Any] = ["detailState": state, "mergeable": "MERGEABLE",
      "head": String(repeating: "a", count: 40), "statusCheckRollup": [],
      "pullRequests": [["number": 42, "url": request.url, "title": request.title,
        "isDraft": false, "headRefName": "fix", "baseRefName": "main", "isCrossRepository": false]]]
    value.merge(extra) { _, newer in newer }
    try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }

  func testLiveMergedClosedAndClearChecksPauseWithOnePersistentResult() async throws {
    for (state, outcome, text) in [("MERGED", "merged", "PR 已合并"),
      ("CLOSED", "closed", "PR 已关闭"), ("OPEN", "checks_clear", "PR 仍保持开放")] {
      let (store, root, watch, service) = try await fixture()
      try save(state: state, at: root)
      let at = Date()
      await store.runAutomation(watch.id, scheduledAt: at,
        readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
      let paused = try XCTUnwrap(AutomationStorage.load(root: store.dataRoot).items.first)
      XCTAssertFalse(paused.enabled)
      XCTAssertNil(paused.completedAt, "An infinite heartbeat remains a paused schedule")
      XCTAssertEqual(paused.pausedAt, at)
      XCTAssertEqual(paused.watchedPullRequest?.state, state)
      XCTAssertEqual(paused.watchedPullRequest?.checkedAt, at)
      XCTAssertEqual(paused.taskID, watch.taskID)
      let result = try XCTUnwrap(store.library.chatRuns.last)
      XCTAssertEqual(result.status, "succeeded")
      XCTAssertEqual(result.result?["watch_preflight_outcome"].text, outcome)
      XCTAssertTrue(result.result?["response"].text?.contains(text) == true)
      XCTAssertTrue(result.result?["response"].text?.contains(request.url) == true)
      XCTAssertNil(result.request["model"].text)
      XCTAssertEqual(paused.lastRunID, result.id)
      XCTAssertTrue(paused.needsReview)
      XCTAssertTrue(store.library.unreadTasks.contains(watch.taskID!))
      XCTAssertEqual(store.library.tasks.count, 2)
      XCTAssertTrue(store.library.managedWorktrees.isEmpty)
      XCTAssertNil(store.automationsError)
      XCTAssertEqual(store.selection, "source")
      XCTAssertEqual(store.draft, "Source draft")
      XCTAssertEqual(store.notices.items.first?.taskID, "source")
      XCTAssertEqual(store.notices.items.first?.watchAutomationID, watch.id)
      let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(restored.chatRuns.last, result)
      XCTAssertEqual(restored.task(containing: result.id)?.id, watch.taskID)
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
        XCTFail("Paused schedule must not read again")
        throw CancellationError()
      })
      await store.runDueAutomations(now: at.addingTimeInterval(3600))
      XCTAssertEqual(store.library.chatRuns.count, 2)
    }
  }

  func testIncompleteOrConflictChecksCannotProduceCompletedResult() async throws {
    for extra: [String: Any] in [
      ["statusCheckRollup": [["status": "IN_PROGRESS"]]],
      ["statusCheckRollup": [["conclusion": "FAILURE"]]],
      ["mergeable": "CONFLICTING"], ["statusCheckRollup": NSNull()],
    ] {
      let (store, root, watch, service) = try await fixture()
      try save(state: "OPEN", at: root, extra: extra)
      await store.runAutomation(watch.id, readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
      XCTAssertTrue(store.automationPreferences.items[0].enabled)
      XCTAssertNil(store.automationPreferences.items[0].pausedAt)
      XCTAssertFalse(store.library.chatRuns.contains { $0.result?["watch_preflight_outcome"].text != nil })
    }
  }

  func testUnrecognizedStateRetriesWithoutInventingClosure() async throws {
    let (store, _, watch, _) = try await fixture()
    let at = Date()
    let unknown = GitHubPRDetails(number: 42, url: request.url, title: "Fix", body: nil,
      state: "UNKNOWN", isDraft: false, headRefName: "fix", baseRefName: "main",
      reviewDecision: nil, mergeable: "MERGEABLE", statusCheckRollup: [])
    await store.runAutomation(watch.id, scheduledAt: at, readWatchedPullRequest: { _, _ in unknown })
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertNil(store.automationPreferences.items[0].pausedAt)
    XCTAssertEqual(store.automationPreferences.items[0].nextRun.timeIntervalSince(at), 300, accuracy: 0.001)
    XCTAssertEqual(store.library.chatRuns.count, 1)
  }

  func testGreenResumeRetainsResultAndReviewHistoryWithoutForkingAgain() async throws {
    let (store, root, watch, service) = try await fixture()
    await store.runAutomation(watch.id, readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
    let first = try XCTUnwrap(store.library.chatRuns.last)
    let resumed = await store.startPullRequestWatch(request, taskID: "source", root: root,
      read: { try await service.details(for: $0, at: $1) }, runImmediately: false)
    XCTAssertTrue(resumed)
    XCTAssertTrue(store.automationPreferences.items[0].enabled)
    XCTAssertNil(store.automationPreferences.items[0].pausedAt)
    XCTAssertEqual(store.automationPreferences.items[0].taskID, watch.taskID)
    await store.runAutomation(watch.id, readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
    let latest = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertNotEqual(latest.id, first.id)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertEqual(store.automationPreferences.items[0].unresolvedRunIDs, [first.id, latest.id])
    store.markAutomationReviewed(watch.id, runID: first.id)
    XCTAssertEqual(store.automationPreferences.items[0].unresolvedRunIDs, [latest.id])
    XCTAssertEqual(store.library.task(containing: latest.id)?.id, watch.taskID)
  }

  func testCompletionSaveFailuresNeverClaimFullSuccess() async throws {
    for failSchedule in [true, false] {
      let (store, _, watch, service) = try await fixture()
      let file = store.dataRoot.appendingPathComponent(failSchedule ? "automations.json" : "workspace.json")
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      await store.runAutomation(watch.id, readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
      XCTAssertEqual(store.library.chatRuns.count, 1)
      XCTAssertEqual(store.notices.items.first?.level, .error)
      XCTAssertEqual(store.automationPreferences.items[0].enabled, failSchedule)
      XCTAssertNotNil(store.automationsError)
      if !failSchedule {
        XCTAssertFalse(try AutomationStorage.load(root: store.dataRoot).items[0].enabled)
        XCTAssertTrue(store.automationsError?.contains("结束记录保存失败") == true)
      }
    }
  }

  func testLateCompletionCannotPauseReplacementTaskOrProject() async throws {
    for changeProject in [false, true] {
      let (store, _, watch, service) = try await fixture()
      let snapshot = try await service.details(for: request, at: URL(fileURLWithPath: watch.project))
      await store.runAutomation(watch.id, readWatchedPullRequest: { _, _ in
        await MainActor.run {
          var replacement = watch
          if changeProject { replacement.project += "/other"; replacement.projects = [replacement.project] }
          else { replacement.taskID = UUID().uuidString }
          XCTAssertTrue(store.saveAutomation(replacement))
        }
        return snapshot
      })
      XCTAssertTrue(store.automationPreferences.items[0].enabled)
      XCTAssertNil(store.automationPreferences.items[0].pausedAt)
      XCTAssertEqual(store.library.chatRuns.count, 1)
    }
  }

  func testLegacyUnlimitedWatchLoadsAsPausedAndFiniteScheduleKeepsCompletion() async throws {
    let (store, _, watch, _) = try await fixture()
    var old = watch
    old.enabled = false; old.completedAt = .now
    XCTAssertTrue(store.saveAutomation(old))
    let file = store.dataRoot.appendingPathComponent("automations.json")
    let original = try Data(contentsOf: file)
    let loaded = try XCTUnwrap(AutomationStorage.load(root: store.dataRoot).items.first)
    XCTAssertFalse(loaded.enabled)
    XCTAssertNil(loaded.completedAt)
    XCTAssertEqual(loaded.pausedAt, old.completedAt)
    XCTAssertEqual(loaded.taskID, watch.taskID)
    XCTAssertEqual(try Data(contentsOf: file), original, "Reading must not rewrite history")
    store.automationPreferences.items = [loaded]
    XCTAssertTrue(store.saveAutomation(loaded))
    let saved = try JSONDecoder().decode(AutomationPreferences.self, from: Data(contentsOf: file))
    XCTAssertNil(saved.items[0].completedAt)
    XCTAssertEqual(saved.items[0].pausedAt, old.completedAt)
    old.customRule = "FREQ=MINUTELY;INTERVAL=10;COUNT=1"
    XCTAssertTrue(store.saveAutomation(old))
    XCTAssertEqual(try AutomationStorage.load(root: store.dataRoot).items[0].completedAt, old.completedAt)
    old.watchedPullRequest = nil
    old.customRule = "FREQ=MINUTELY;INTERVAL=10"
    XCTAssertTrue(store.saveAutomation(old))
    XCTAssertEqual(try AutomationStorage.load(root: store.dataRoot).items[0].completedAt, old.completedAt)
  }

  func testNativeCompletedProgressRetainsReplyComposerAndSourceDraft() async throws {
    let (store, _, watch, service) = try await fixture()
    await store.runAutomation(watch.id, readWatchedPullRequest: { try await service.details(for: $0, at: $1) })
    store.setTaskWindowDraft("Continue monitoring", taskID: watch.taskID!)
    let tab = WorkspaceContentTab.pullRequestWatch(watch.id, task: watch.taskID!, owner: "source")
    let view = PullRequestWatchProgressView(store: store, tab: tab, close: {})
    let host = NSHostingView(rootView: view.frame(width: 430, height: 680))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 680),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(700)); host.layoutSubtreeIfNeeded()
    func editors(_ view: NSView) -> [ComposerNativeTextView] {
      ((view as? ComposerNativeTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
    }
    let editor = try XCTUnwrap(editors(host).first)
    XCTAssertEqual(editor.string, "Continue monitoring")
    editor.selectAll(nil); editor.insertText("Human follow up", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.taskWindowDraft(watch.taskID!), "Human follow up")
    XCTAssertEqual(store.selection, "source"); XCTAssertEqual(store.draft, "Source draft")
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
      let target = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: target.appendingPathComponent("pr-watch-completed-progress.png"))
      let result = try XCTUnwrap(store.library.chatRuns.last)
      let inspector = NSHostingView(rootView: ChatRunInspectorView(store: store,
        run: result, tab: .constant("overview"), close: {}).frame(width: 430, height: 420))
      let detailsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 420),
        styleMask: [.titled], backing: .buffered, defer: true)
      detailsWindow.isReleasedWhenClosed = false; detailsWindow.contentView = inspector
      defer { detailsWindow.contentView = nil; detailsWindow.close() }
      try await Task.sleep(for: .milliseconds(100)); inspector.layoutSubtreeIfNeeded()
      let detailBitmap = try XCTUnwrap(inspector.bitmapImageRepForCachingDisplay(in: inspector.bounds))
      inspector.cacheDisplay(in: inspector.bounds, to: detailBitmap)
      try XCTUnwrap(detailBitmap.representation(using: .png, properties: [:]))
        .write(to: target.appendingPathComponent("pr-watch-completed-inspector.png"))
    }
  }
}
