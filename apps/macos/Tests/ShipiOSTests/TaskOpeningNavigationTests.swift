import XCTest
@testable import ShipiOS

@MainActor final class TaskOpeningNavigationTests: XCTestCase {
  private enum Route { case notification, notice, activity }
  private struct Fixture {
    let store: WorkspaceStore
    let root: URL
    let source: URL
    let target: URL
  }

  private func fixture() async throws -> Fixture {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("task-opening-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let root = temporary.resolvingSymlinksInPath()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    let target = root.appendingPathComponent("target", isDirectory: true)
    for folder in [source, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let agent = root.appendingPathComponent("agent")
    try #"""
      #!/usr/bin/python3
      import json, os, pathlib, sys, time
      root = pathlib.Path(__file__).parent
      project = sys.argv[sys.argv.index('--project') + 1]
      for line in sys.stdin:
          request = json.loads(line); method = request['method']
          response = {'jsonrpc': '2.0', 'id': request['id']}
          if os.path.basename(project) == 'target' and method == 'project.inspect':
              (root / 'ready').write_text('ready')
              deadline = time.monotonic() + 5
              while not (root / 'release').exists() and time.monotonic() < deadline:
                  time.sleep(.01)
              if (root / 'fail').exists():
                  response['error'] = {'code': -32000, 'message': 'target fixture failed'}
          if 'error' not in response:
              values = {'initialize': {'protocolVersion': 1},
                        'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [],
                                            'diagnostics': [], 'scanTruncated': False},
                        'config.get': {}, 'run.list': [], 'environment.list': []}
              response['result'] = values.get(method, {})
          print(json.dumps(response), flush=True)
      """#.write(to: agent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: agent)
    addTeardownBlock { @MainActor in _ = await store.shutdown() }
    await store.restore(); await store.open(source)
    XCTAssertTrue(store.connected)
    store.library.tasks = [.init(id: "source", project: source.path, title: "Source", runIDs: []),
      .init(id: "target", project: target.path, title: "Target", runIDs: ["target-run"])]
    store.library.chatRuns = [.init(id: "target-run", kind: "chat", project: target.path,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null, result: .object(["response": .string("Target reply")]))]
    store.library.drafts["target"] = "target draft"
    store.selectTask(store.library.tasks[0]); store.draft = "source draft"
    store.setTaskUnread("target", unread: true)
    store.workspace.fileText = "source preview"
    return .init(store: store, root: root, source: source, target: target)
  }

  private func begin(_ route: Route, fixture f: Fixture) throws -> Task<Bool, Never> {
    switch route {
    case .notification:
      let target = NotificationDestination(dataRoot: f.store.dataRoot.path, project: f.target.path,
        taskID: "target", runID: "target-run")
      return Task { await f.store.openNotification(target) }
    case .notice:
      f.store.notices.show(id: "open-target", title: "Target ready", level: .success, taskID: "target")
      let notice = try XCTUnwrap(f.store.notices.items.first)
      return Task {
        await f.store.openNoticeTask(notice)
        return f.store.selectedTask?.id == "target"
      }
    case .activity:
      f.store.toggleActivity()
      return Task { await f.store.openActivityTask("target") }
    }
  }

  private func waitUntilReady(_ root: URL) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Target did not begin opening") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func checkAbandoned(_ route: Route, failure: Bool = false, roundTrip: Bool = false) async throws {
    let f = try await fixture(), store = f.store
    if failure { try Data().write(to: f.root.appendingPathComponent("fail")) }
    let opening = try begin(route, fixture: f)
    defer { opening.cancel() }
    try await waitUntilReady(f.root)
    store.destination = .projects
    if roundTrip { store.destination = .workspace }
    store.draft = "newer source draft"
    store.workspace.fileText = "newer source preview"
    try Data().write(to: f.root.appendingPathComponent("release"))
    let opened = await opening.value
    XCTAssertFalse(opened)
    XCTAssertEqual(store.destination, roundTrip ? .workspace : .projects)
    XCTAssertEqual(store.project?.path, f.source.path)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "newer source draft")
    XCTAssertEqual(store.workspace.fileText, "newer source preview")
    XCTAssertEqual(store.library.drafts["target"], "target draft")
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertNil(store.conversationReveal)
    XCTAssertNil(store.error)
    XCTAssertNil(store.projectRecoveryPath)
    XCTAssertNil(store.activityError)
    XCTAssertNil(store.activityOpeningTaskID)
    XCTAssertFalse(store.busy)
    if route == .notice {
      let notice = try XCTUnwrap(store.notices.items.first { $0.id == "open-target" })
      XCTAssertEqual(notice.level, .success, "An abandoned open cannot leave an infinite pending notice")
      XCTAssertEqual(notice.title, "Target ready")
      XCTAssertEqual(notice.taskID, "target")
    }
  }

  func testNotificationLateSuccessCannotPullBackNewPageOrReplaceDraft() async throws {
    try await checkAbandoned(.notification)
  }

  func testNoticeLateSuccessCannotPullBackNewPageOrReplaceDraft() async throws {
    try await checkAbandoned(.notice)
  }
  func testActivityLateSuccessCannotPullBackNewPageOrReplaceDraft() async throws {
    try await checkAbandoned(.activity)
  }
  func testNotificationLateFailureDoesNotPublishOldError() async throws {
    try await checkAbandoned(.notification, failure: true)
  }
  func testNoticeLateFailureRestoresRetryActionWithoutOldError() async throws {
    try await checkAbandoned(.notice, failure: true)
  }
  func testActivityLateFailureDoesNotPublishOldError() async throws {
    try await checkAbandoned(.activity, failure: true)
  }
  func testNotificationLeaveAndReturnStillAbandonsOldOpen() async throws {
    try await checkAbandoned(.notification, roundTrip: true)
  }
  func testNoticeLeaveAndReturnStillAbandonsOldOpen() async throws {
    try await checkAbandoned(.notice, roundTrip: true)
  }
  func testActivityLeaveAndReturnStillAbandonsOldOpen() async throws {
    try await checkAbandoned(.activity, roundTrip: true)
  }

  private func checkSuccessfulOpen(_ route: Route, retry: Bool = false) async throws {
    let f = try await fixture(), store = f.store
    if retry {
      try Data().write(to: f.root.appendingPathComponent("fail"))
      let first = try begin(route, fixture: f)
      try await waitUntilReady(f.root)
      try Data().write(to: f.root.appendingPathComponent("release"))
      let opened = await first.value
      XCTAssertFalse(opened)
      XCTAssertEqual(store.selectedTask?.id, "source")
      XCTAssertEqual(store.project?.path, f.source.path)
      XCTAssertEqual(store.draft, "source draft")
      XCTAssertEqual(store.workspace.fileText, "source preview")
      XCTAssertTrue(store.library.unreadTasks.contains("target"))
      XCTAssertNil(store.conversationReveal)
      XCTAssertNotNil(store.error)
      XCTAssertFalse(store.busy)
      if route == .notice {
        let notice = try XCTUnwrap(store.notices.items.first { $0.id == "open-target" })
        XCTAssertEqual(notice.level, .error)
        XCTAssertEqual(notice.taskID, "target")
      }
      if route == .activity { XCTAssertNotNil(store.activityError) }
      try FileManager.default.removeItem(at: f.root.appendingPathComponent("fail"))
      try FileManager.default.removeItem(at: f.root.appendingPathComponent("ready"))
      try FileManager.default.removeItem(at: f.root.appendingPathComponent("release"))
    }
    // Retry the existing failure action rather than replacing it with a new notice/session.
    let second: Task<Bool, Never>
    if retry && route == .notice {
      let notice = try XCTUnwrap(store.notices.items.first { $0.id == "open-target" })
      second = Task { await store.openNoticeTask(notice); return store.selectedTask?.id == "target" }
    } else if retry && route == .activity {
      second = Task { await store.openActivityTask("target") }
    } else { second = try begin(route, fixture: f) }
    try await waitUntilReady(f.root)
    try Data().write(to: f.root.appendingPathComponent("release"))
    let opened = await second.value
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.project?.path, f.target.path)
    XCTAssertEqual(store.selectedTask?.id, "target")
    XCTAssertEqual(store.draft, "target draft")
    XCTAssertEqual(store.library.drafts["source"], "source draft")
    XCTAssertFalse(store.library.unreadTasks.contains("target"))
    XCTAssertTrue(store.connected)
    XCTAssertNil(store.error)
    XCTAssertNil(store.activityError)
    XCTAssertNil(store.activityOpeningTaskID)
    XCTAssertFalse(store.busy)
    if route == .notification { XCTAssertEqual(store.conversationReveal?.runID, "target-run") }
    else { XCTAssertNil(store.conversationReveal) }
    if route == .notice {
      XCTAssertFalse(store.notices.items.contains { $0.id == "open-target" && $0.level == .pending })
    }
  }

  func testNotificationValidOpenRevealsExactRunAndKeepsSourceDraft() async throws {
    try await checkSuccessfulOpen(.notification)
  }
  func testNoticeValidOpenKeepsBothDrafts() async throws { try await checkSuccessfulOpen(.notice) }
  func testActivityValidOpenKeepsBothDrafts() async throws { try await checkSuccessfulOpen(.activity) }
  func testNotificationFailureThenExplicitRetry() async throws {
    try await checkSuccessfulOpen(.notification, retry: true)
  }
  func testNoticeFailureThenExistingActionRetry() async throws {
    try await checkSuccessfulOpen(.notice, retry: true)
  }
  func testActivityFailureThenExistingSessionRetry() async throws {
    try await checkSuccessfulOpen(.activity, retry: true)
  }

  func testClosingActivityDuringOpenPreservesSource() async throws {
    let f = try await fixture(), store = f.store
    let opening = try begin(.activity, fixture: f)
    try await waitUntilReady(f.root)
    store.closeActivity()
    try Data().write(to: f.root.appendingPathComponent("release"))
    let opened = await opening.value
    XCTAssertFalse(opened)
    XCTAssertNil(store.activitySession)
    XCTAssertEqual(store.project?.path, f.source.path)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertNil(store.activityError)
    XCTAssertFalse(store.busy)
  }

  func testReplacedNoticeDuringOpenCannotBeOverwrittenOrNavigate() async throws {
    let f = try await fixture(), store = f.store
    let opening = try begin(.notice, fixture: f)
    try await waitUntilReady(f.root)
    store.notices.show(id: "open-target", title: "Newer notice", level: .info, taskID: "source")
    let replacement = try XCTUnwrap(store.notices.items.first { $0.id == "open-target" })
    try Data().write(to: f.root.appendingPathComponent("release"))
    let opened = await opening.value
    XCTAssertFalse(opened)
    XCTAssertEqual(store.notices.items.first { $0.id == "open-target" }, replacement)
    XCTAssertEqual(store.project?.path, f.source.path)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "source draft")
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertNil(store.error)
    XCTAssertFalse(store.busy)
  }
}
