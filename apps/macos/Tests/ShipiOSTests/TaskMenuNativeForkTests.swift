import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class TaskMenuNativeForkTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore
    let root: URL
    let source: WorkspaceTask
    let childThread: String
    var started: URL { root.appendingPathComponent("started.json") }
    var release: URL { root.appendingPathComponent("release") }
    var trace: URL { root.appendingPathComponent("trace.jsonl") }
  }

  private func fixture(mode: String = "success", projectless: Bool = false) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-native-fork-\(UUID())")
      .resolvingSymlinksInPath().standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let childThread = UUID().uuidString
    let executable = root.appendingPathComponent("agent-fixture")
    let script = #"""
      #!/usr/bin/python3
      import json, os, sys, time
      root = os.path.dirname(os.path.abspath(__file__))
      project = sys.argv[sys.argv.index('--project') + 1]
      mode = json.load(open(os.path.join(root, 'mode.json')))
      child = json.load(open(os.path.join(root, 'child.json')))
      for line in sys.stdin:
          request = json.loads(line)
          method = request['method']
          params = request.get('params', {})
          with open(os.path.join(root, 'trace.jsonl'), 'a') as out:
              out.write(json.dumps({'method': method, 'taskId': params.get('taskId')}) + '\n')
          response = {'jsonrpc': '2.0', 'id': request['id']}
          if method == 'codex.thread.start':
              mode = json.load(open(os.path.join(root, 'mode.json')))
              with open(os.path.join(root, 'started.tmp'), 'w') as out:
                  json.dump({'taskId': params['taskId'], 'resumeOnly': params['resumeOnly'],
                             'forkOrigin': params['forkOrigin'], 'project': project,
                             'model': params['model'], 'permissions': params['permissions']}, out)
              os.replace(os.path.join(root, 'started.tmp'), os.path.join(root, 'started.json'))
              deadline = time.monotonic() + 10
              while not os.path.exists(os.path.join(root, 'release')) and time.monotonic() < deadline:
                  time.sleep(0.01)
              if mode == 'error':
                  response['error'] = {'code': -32000, 'message': 'fixture native history unavailable'}
              else:
                  response['result'] = {'threadId': child if mode != 'invalid-id' else 'invalid',
                                        'forked': mode != 'not-forked', 'resumed': mode == 'resumed'}
          else:
              values = {'initialize': {'protocolVersion': 1},
                        'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [],
                                            'diagnostics': [], 'scanTruncated': False},
                        'config.get': {}, 'run.list': [], 'environment.list': []}
              response['result'] = values.get(method, {})
          print(json.dumps(response), flush=True)
      """#
    try Data(script.utf8).write(to: executable)
    try JSONEncoder().encode(mode).write(to: root.appendingPathComponent("mode.json"))
    try JSONEncoder().encode(childThread).write(to: root.appendingPathComponent("child.json"))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: executable)
    await store.restore()
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    if !projectless { await store.open(project) }
    var config = ModelConfiguration()
    config.apiProtocol = .codexResponses; config.baseURL = "http://127.0.0.1:9/v1"; config.model = "fixture"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let thread = UUID().uuidString, turn = UUID().uuidString
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: projectless ? "" : project.path,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null,
      result: .object(["response": .string("reply"), "codex_thread_id": .string(thread),
        "codex_turn_id": .string(turn)]))
    let source = WorkspaceTask(id: UUID().uuidString, project: run.project,
      title: String(repeating: "聊天标题", count: 40), runIDs: [run.id],
      codexThreadID: thread, codexWorkspacePath: project.path)
    store.library.tasks = [source]
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "source prompt"
    store.selectTask(source)
    store.draft = "keep current draft"
    return Fixture(store: store, root: root, source: source, childThread: childThread)
  }

  private func waitUntilStarted(_ fixture: Fixture) async throws -> JSONValue {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: fixture.started.path) {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Native fork request did not start") }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixture.started))
  }

  private func waitUntilPreparationFinishes(_ store: WorkspaceStore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.managedTaskPreparing {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Worktree preparation did not finish") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func events(_ fixture: Fixture) throws -> [JSONValue] {
    try String(contentsOf: fixture.trace).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  private func prepareWorktreeRepository(_ f: Fixture) async throws {
    let project = URL(fileURLWithPath: f.source.project)
    _ = try await GitReviewService.checked(["init", "-q"], at: project)
    _ = try await GitReviewService.checked(["config", "user.name", "Fixture"], at: project)
    _ = try await GitReviewService.checked(["config", "user.email", "fixture@example.invalid"], at: project)
    try Data("initial\n".utf8).write(to: project.appendingPathComponent("tracked"))
    _ = try await GitReviewService.checked(["add", "."], at: project)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: project)
    f.store.library.newTaskEnvironmentSelections[project.path] = WorktreeEnvironmentChoice.legacy
    f.store.library.profiles[project.path] = BuildProfile(worktreeSetupScript: "printf 'setup\\n' >> setup-count")
    XCTAssertTrue(f.store.saveLibrary())
  }

  func testNewWorktreeCompletionDoesNotReplacePageChosenWhilePreparing() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id) }
    _ = try await waitUntilStarted(f)
    XCTAssertFalse(store.busy, "Preparing a child must not own the main project navigation lock")
    store.destination = .settings
    store.draft = "source draft while visiting settings"
    try Data().write(to: f.release)
    let result = await operation.value
    let child = try XCTUnwrap(result)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.library.drafts[f.source.id], "source draft while visiting settings")
    XCTAssertEqual(child.codexThreadID, f.childThread)
    await store.shutdown()
  }

  func testPreparingPageBackKeepsSourceDraftAndCompletionStaysInBackground() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id) }
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(store.worktreeForkPresentation.preparation)
    XCTAssertEqual(page.state, .preparing)
    XCTAssertEqual(page.phase, "正在创建原生聊天分支…")
    XCTAssertEqual(page.title, f.source.title)
    XCTAssertEqual(page.taskID, store.library.managedWorktrees.first?.taskID)
    XCTAssertEqual(store.project?.path, f.source.project)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertFalse(store.mainMCPApprovalVisible)
    XCTAssertFalse(store.commandEnabled("approval-decline"))
    XCTAssertTrue(store.commandEnabled("back"))
    await store.navigate(back: true)
    XCTAssertNil(store.worktreeForkPresentation.preparation)
    XCTAssertEqual(store.draft, "keep current draft")
    store.newTask()
    store.draft = "new unsent task while preparing"
    try Data().write(to: f.release)
    let result = await operation.value
    let child = try XCTUnwrap(result)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.draft, "new unsent task while preparing")
    XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
    XCTAssertEqual(page.state, .ready)
    XCTAssertTrue(store.notices.items.contains { $0.id == "worktree-fork-ready-" + child.id && $0.taskID == child.id })
    await store.shutdown()
  }

  func testPageCancelAndContinueRetainsTargetAndNeverRepeatsSuccessfulSetup() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id) }
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(store.worktreeForkPresentation.preparation)
    let id = try XCTUnwrap(page.taskID), path = try XCTUnwrap(page.path)
    store.setTaskWindowDraft("target draft before cancellation", taskID: id)
    page.cancel()
    let cancelled = await operation.value
    XCTAssertNil(cancelled)
    XCTAssertEqual(page.state, .cancelled)
    XCTAssertTrue(store.worktreeForkPresentation.owns(page))
    XCTAssertFalse(store.busy)
    XCTAssertFalse(store.managedTaskPreparing)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.library.managedWorktrees.first?.pendingForkSourceTaskID, f.source.id)
    XCTAssertFalse(store.codexTransport.isConnected(taskID: id))
    try Data().write(to: f.release)
    await store.retryWorktreeFork(in: store.worktreeForkPresentation)
    XCTAssertNil(store.worktreeForkPresentation.preparation)
    XCTAssertEqual(store.selectedTask?.id, id)
    XCTAssertEqual(store.draft, "target draft before cancellation")
    XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("setup-count")), "setup\n")
    await store.shutdown()
  }

  func testWindowPreparationUsesItsOwnPageAndNoticesAndDoesNotNavigateAfterLeaving() async throws {
    let f = try await fixture(mode: "error"), store = f.store
    try await prepareWorktreeRepository(f)
    let resources = TaskWindowResources()
    resources.prepare(f.source.id, store: store)
    resources.display(f.source.id)
    var navigated: [String] = []
    resources.navigate = { navigated.append($0) }
    resources.forkToNewWorktree(f.source.id, store: store)
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(resources.worktreeForkPresentation.preparation)
    XCTAssertNil(store.worktreeForkPresentation.preparation)
    XCTAssertTrue(page.notices === resources.notices)
    resources.worktreeForkPresentation.dismiss()
    try Data().write(to: f.release)
    let worker = try XCTUnwrap(page.operation)
    _ = await worker.value
    // The public waiter finalizes the page on the next main-actor continuation.
    try await waitUntilPreparationFinishes(store)
    XCTAssertTrue(navigated.isEmpty)
    XCTAssertTrue(resources.notices.items.contains { $0.level == .error && $0.taskID == page.taskID })
    XCTAssertFalse(store.notices.items.contains { $0.level == .error })
    XCTAssertNil(store.error)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    resources.worktreeForkPresentation.present(page)
    try JSONEncoder().encode("success").write(to: f.root.appendingPathComponent("mode.json"))
    await store.retryWorktreeFork(in: resources.worktreeForkPresentation)
    XCTAssertEqual(navigated, [try XCTUnwrap(page.taskID)])
    XCTAssertNil(resources.worktreeForkPresentation.preparation)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertTrue(resources.shutdown(force: true))
    await store.shutdown()
  }

  func testQueuedWindowWorktreeForkCannotStartAfterNavigationRoundTripOrClose() async throws {
    for action in ["switch", "roundtrip", "close"] {
      let f = try await fixture(), store = f.store
      try await prepareWorktreeRepository(f)
      let other = WorkspaceTask(id: UUID().uuidString, project: f.source.project, title: "Other", runIDs: [])
      store.library.tasks.append(other)
      let resources = TaskWindowResources()
      resources.prepare(f.source.id, store: store); resources.display(f.source.id)
      var navigated: [String] = []
      resources.navigate = { navigated.append($0) }
      try Data().write(to: f.release)
      let operation = try XCTUnwrap(resources.forkToNewWorktree(f.source.id, store: store))
      if action == "close" { XCTAssertTrue(resources.shutdown(force: true)) }
      else {
        resources.display(other.id)
        if action == "roundtrip" { resources.display(f.source.id) }
      }
      await operation.value
      XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id, other.id], action)
      XCTAssertTrue(store.library.managedWorktrees.isEmpty, action)
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.started.path), action)
      XCTAssertTrue(navigated.isEmpty, action)
      XCTAssertNil(resources.worktreeForkPresentation.preparation, action)
      XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
      XCTAssertTrue(resources.shutdown(force: true))
      await store.shutdown()
    }
  }

  func testLatestQueuedWindowWorktreeForkUsesItsRequestedSourceAndCallback() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    var other = f.source
    other.id = UUID().uuidString; other.title = "Other requested source"
    other.codexThreadID = UUID().uuidString
    let otherRun = AgentRun(id: UUID().uuidString, kind: "chat", project: other.project,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null,
      result: .object(["response": .string("other source reply"),
        "codex_thread_id": .string(try XCTUnwrap(other.codexThreadID)),
        "codex_turn_id": .string(UUID().uuidString)]))
    other.runIDs = [otherRun.id]
    store.library.chatRuns.append(otherRun)
    store.library.notes[otherRun.id] = "other source prompt"
    store.library.tasks.append(other)
    let resources = TaskWindowResources()
    resources.prepare(f.source.id, store: store); resources.display(f.source.id)
    var navigated: [String] = []
    resources.navigate = { navigated.append($0) }
    try Data().write(to: f.release)
    let first = try XCTUnwrap(resources.forkToNewWorktree(f.source.id, store: store))
    resources.display(other.id)
    let latest = try XCTUnwrap(resources.forkToNewWorktree(other.id, store: store))
    await first.value; await latest.value
    let children = store.library.tasks.filter { ![f.source.id, other.id].contains($0.id) }
    XCTAssertEqual(children.count, 1)
    XCTAssertEqual(children.first?.title, other.title)
    XCTAssertEqual(children.first?.forkOrigin?.taskID, other.id)
    XCTAssertEqual(children.first.map { store.library.chatContext(taskID: $0.id).map(\.content) },
      ["other source prompt", "other source reply"])
    let started = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.started))
    XCTAssertEqual(started["forkOrigin"]["taskId"].text, other.id)
    XCTAssertEqual(navigated, children.map(\.id))
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertNil(resources.worktreeForkPresentation.preparation)
    XCTAssertTrue(resources.shutdown(force: true))
    await store.shutdown()
  }

  func testActiveWindowWorktreeRequestRejectsAnotherActionWithoutReplacingItsCancellation() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let resources = TaskWindowResources()
    resources.prepare(f.source.id, store: store); resources.display(f.source.id)
    let first = try XCTUnwrap(resources.forkToNewWorktree(f.source.id, store: store))
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(resources.worktreeForkPresentation.preparation)
    XCTAssertNil(resources.forkToNewWorktree(f.source.id, store: store))
    XCTAssertTrue(resources.worktreeForkPresentation.owns(page))
    first.cancel()
    await first.value
    XCTAssertEqual(page.state, .cancelled)
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertNotNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertTrue(resources.shutdown(force: true))
    await store.shutdown()
  }

  func testExplicitProjectNavigationLeavesCancelledFailedAndReadyPreparationPages() async throws {
    for state in [WorktreeForkPreparation.State.cancelled, .failed("fixture failure"), .ready] {
      let f = try await fixture(), store = f.store
      let page = WorktreeForkPreparation(sourceTaskID: f.source.id, title: f.source.title,
        notices: store.notices)
      page.state = state
      let other = f.root.appendingPathComponent("other-project")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      store.worktreeForkPresentation.present(page)
      await store.open(other)
      XCTAssertEqual(store.currentProjectKey, other.path)
      XCTAssertNil(store.worktreeForkPresentation.preparation, "Direct project selection must leave \(state)")
      store.worktreeForkPresentation.present(page)
      let opened = await store.openTaskScope(other.path)
      XCTAssertTrue(opened)
      XCTAssertNil(store.worktreeForkPresentation.preparation, "Same-scope navigation must leave \(state)")
      store.worktreeForkPresentation.present(page)
      await store.openProjectless()
      XCTAssertEqual(store.currentProjectKey, "")
      XCTAssertNil(store.worktreeForkPresentation.preparation, "Projectless navigation must leave \(state)")
      XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
      await store.shutdown()
    }
  }

  func testColdPendingWindowRegistersRestoredIdentityBeforeResumingAndOpeningScope() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let initial = Task { await store.forkTaskToNewWorktree(f.source.id, openTask: false) }
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(store.activeWorktreeForkPreparation)
    page.cancel()
    let cancelled = await initial.value
    XCTAssertNil(cancelled)
    let childID = try XCTUnwrap(page.taskID)
    let resources = TaskWindowResources(), windowID = UUID().uuidString
    resources.register(store: store, windowID: windowID)
    XCTAssertEqual(resources.id, windowID)
    XCTAssertTrue(resources.tasks.isEmpty, "Registration must not open a pending checkout scope")
    var navigated: [String] = []
    resources.navigate = { target in
      resources.prepare(target, store: store, windowID: windowID)
      resources.display(target)
      navigated.append(target)
    }
    resources.forkToNewWorktree(childID, store: store, resume: true)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.activeWorktreeForkPreparation == nil {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Window preparation did not start") }
      try await Task.sleep(for: .milliseconds(10))
    }
    let resumed = try XCTUnwrap(resources.worktreeForkPresentation.preparation)
    try Data().write(to: f.release)
    _ = await resumed.value()
    XCTAssertEqual(navigated, [childID])
    XCTAssertEqual(resources.id, windowID)
    XCTAssertEqual(resources.displayedTaskID, childID)
    XCTAssertNil(resources.worktreeForkPresentation.preparation)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertTrue(resources.shutdown(force: true))
    await store.shutdown()
  }

  func testClosingTaskWindowCancelsCreationAndSuppressesLateNavigation() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let resources = TaskWindowResources()
    resources.prepare(f.source.id, store: store)
    resources.display(f.source.id)
    var navigated = false
    resources.navigate = { _ in navigated = true }
    resources.forkToNewWorktree(f.source.id, store: store)
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(resources.worktreeForkPresentation.preparation)
    let worker = try XCTUnwrap(page.operation)
    XCTAssertTrue(resources.shutdown(force: true))
    _ = await worker.value
    try await waitUntilPreparationFinishes(store)
    XCTAssertEqual(page.state, .cancelled)
    XCTAssertNil(resources.worktreeForkPresentation.preparation)
    XCTAssertFalse(navigated)
    XCTAssertNotNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    await store.shutdown()
  }

  func testSelectingPendingSidebarTargetShowsPreparationWithoutOpeningItsScope() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id, openTask: false) }
    _ = try await waitUntilStarted(f)
    let page = try XCTUnwrap(store.activeWorktreeForkPreparation)
    let child = try XCTUnwrap(store.library.tasks.first { $0.id == page.taskID })
    XCTAssertNil(store.worktreeForkPresentation.preparation)
    store.selectTask(child)
    XCTAssertTrue(store.worktreeForkPresentation.owns(page))
    XCTAssertEqual(store.currentProjectKey, f.source.project)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    store.selectTask(f.source)
    XCTAssertNil(store.worktreeForkPresentation.preparation)
    try Data().write(to: f.release)
    _ = await operation.value
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    await store.shutdown()
  }

  func testNativeActualMainPreparationCancelAndRetryActionsStayInExistingWindow() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires an explicitly enabled interactive macOS foreground session; hidden NSHostingView has no accessibility children.")
    }
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 750),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceView(store: store))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.contentView = nil; window.close() }
    func element(_ identifier: String, in object: Any) -> (any NSAccessibilityProtocol)? {
      guard let node = object as? any NSAccessibilityProtocol else { return nil }
      if node.accessibilityIdentifier() == identifier { return node }
      for child in node.accessibilityChildren() ?? [] {
        if let found = element(identifier, in: child) { return found }
      }
      return nil
    }
    func find(_ identifier: String) async throws -> any NSAccessibilityProtocol {
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      repeat {
        host.layoutSubtreeIfNeeded()
        if let found = element(identifier, in: host) { return found }
        try await Task.sleep(for: .milliseconds(30))
      } while ContinuousClock.now < deadline
      await store.shutdown()
      throw AgentFailure(message: "Mounted preparation control not found: " + identifier)
    }
    let windows = Set(NSApp.windows.map(\.windowNumber))
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id) }
    _ = try await waitUntilStarted(f)
    let cancel = try await find("worktree-fork-cancel")
    XCTAssertTrue(cancel.accessibilityPerformPress())
    let result = await operation.value
    XCTAssertNil(result)
    XCTAssertEqual(store.worktreeForkPresentation.preparation?.state, .cancelled)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertTrue(window.isVisible)
    XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)), windows)
    try Data().write(to: f.release)
    let retry = try await find("worktree-fork-retry")
    XCTAssertTrue(retry.accessibilityPerformPress())
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.worktreeForkPresentation.preparation != nil {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Retry did not open the child") }
      try await Task.sleep(for: .milliseconds(30))
    }
    XCTAssertNotEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
    XCTAssertEqual(store.library.managedWorktrees.count, 1)
    XCTAssertNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertTrue(window.isVisible)
    await store.shutdown()
  }

  func testNewWorktreeWaitsForNativeAcknowledgmentAndMergesIntoLatestLibraryWithoutModelTurn() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let permissions = AgentRuntimePreferences(approvalPolicy: .never, sandboxMode: .readOnly, networkAccess: false)
    store.library.taskRuntimePreferences[f.source.id] = permissions
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id, openTask: false) }
    let request = try await waitUntilStarted(f)
    let pending = try XCTUnwrap(store.library.managedWorktrees.first)
    let childID = pending.taskID
    XCTAssertTrue(pending.ready)
    XCTAssertEqual(pending.setupCompleted, true)
    XCTAssertEqual(pending.nativeForkRequired, true)
    XCTAssertEqual(pending.pendingForkSourceTaskID, f.source.id)
    XCTAssertFalse(store.canStartChat(taskID: childID))
    XCTAssertNil(store.library.tasks.first { $0.id == childID }?.codexThreadID)
    XCTAssertEqual(request["taskId"].text, childID)
    XCTAssertEqual(request["project"].text, pending.path)
    XCTAssertEqual(request["forkOrigin"]["threadId"].text, f.source.codexThreadID)
    XCTAssertEqual(request["permissions"]["sandboxMode"].text, permissions.sandboxMode.rawValue)
    XCTAssertEqual(request["permissions"]["networkAccess"].boolean, false)
    store.draft = "new source draft during acknowledgement"
    store.library.drafts[childID] = "new child draft"
    var config = store.modelConfiguration
    config.model = "different-model"
    try store.saveModelConfiguration(config)
    try Data().write(to: f.release)
    let result = await operation.value
    let child = try XCTUnwrap(result, store.error ?? "")
    XCTAssertEqual(child.id, childID)
    XCTAssertEqual(child.codexThreadID, f.childThread)
    XCTAssertEqual(child.codexWorkspacePath, pending.path)
    XCTAssertEqual(child.modelSelection?.model, "fixture")
    XCTAssertEqual(store.modelConfiguration(for: childID).model, "fixture")
    XCTAssertEqual(store.runtimePermissions(for: childID), permissions)
    XCTAssertEqual(store.draft, "new source draft during acknowledgement")
    XCTAssertEqual(store.taskWindowDraft(childID), "new child draft")
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
    XCTAssertTrue(store.canStartChat(taskID: childID))
    XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.tasks.first { $0.id == childID }?.codexThreadID, f.childThread)
    XCTAssertNil(saved.managedWorktrees.first?.pendingForkSourceTaskID)
    await store.shutdown()
  }

  func testNewWorktreeCoreFailuresRetainSameCheckpointAndRetryWithoutRepeatingSetup() async throws {
    for mode in ["error", "not-forked", "invalid-id"] {
      let f = try await fixture(mode: mode), store = f.store
      try await prepareWorktreeRepository(f)
      try Data().write(to: f.release)
      let failed = await store.forkTaskToNewWorktree(f.source.id, openTask: false)
      XCTAssertNil(failed, mode)
      let record = try XCTUnwrap(store.library.managedWorktrees.first)
      XCTAssertTrue(record.ready)
      XCTAssertEqual(record.setupCompleted, true)
      XCTAssertEqual(record.pendingForkSourceTaskID, f.source.id)
      XCTAssertNil(store.library.tasks.first { $0.id == record.taskID }?.codexThreadID)
      XCTAssertFalse(store.codexTransport.isConnected(taskID: record.taskID))
      XCTAssertFalse(store.canStartChat(taskID: record.taskID))
      XCTAssertEqual(store.selectedTask?.id, f.source.id)
      XCTAssertEqual(store.draft, "keep current draft")
      try JSONEncoder().encode("success").write(to: f.root.appendingPathComponent("mode.json"))
      let result = await store.resumeWorktreeFork(record.taskID, openTask: false)
      let child = try XCTUnwrap(result, store.error ?? "")
      XCTAssertEqual(child.id, record.taskID)
      XCTAssertEqual(child.codexThreadID, f.childThread)
      XCTAssertEqual(store.library.tasks.count, 2)
      XCTAssertEqual(store.library.managedWorktrees.count, 1)
      XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("setup-count")), "setup\n")
      XCTAssertNil(store.library.managedWorktrees.first?.pendingForkSourceTaskID)
      XCTAssertEqual(try events(f).filter { $0["method"].text == "codex.thread.start" }.count, 2)
      XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
      await store.shutdown()
    }
  }

  func testCancelledNewWorktreeAcknowledgementKeepsRecoverableCheckoutAndDiscardsConnection() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id, openTask: false) }
    _ = try await waitUntilStarted(f)
    let record = try XCTUnwrap(store.library.managedWorktrees.first)
    operation.cancel()
    try Data().write(to: f.release)
    let failed = await operation.value
    XCTAssertNil(failed)
    XCTAssertEqual(store.library.managedWorktrees.first?.pendingForkSourceTaskID, f.source.id)
    XCTAssertNil(store.library.tasks.first { $0.id == record.taskID }?.codexThreadID)
    XCTAssertFalse(store.codexTransport.isConnected(taskID: record.taskID))
    XCTAssertFalse(store.managedTaskPreparing)
    XCTAssertFalse(store.busy)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.draft, "keep current draft")
    let result = await store.resumeWorktreeFork(record.taskID, openTask: false)
    XCTAssertEqual(result?.id, record.taskID, store.error ?? "")
    XCTAssertEqual(result?.codexThreadID, f.childThread)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("setup-count")), "setup\n")
    await store.shutdown()
  }

  func testNewWorktreeFinalSaveFailureDiscardsUnpublishedCoreAndRetryKeepsOriginalCheckout() async throws {
    let f = try await fixture(), store = f.store
    try await prepareWorktreeRepository(f)
    let operation = Task { await store.forkTaskToNewWorktree(f.source.id, openTask: false) }
    _ = try await waitUntilStarted(f)
    let record = try XCTUnwrap(store.library.managedWorktrees.first)
    let workspace = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data().write(to: f.release)
    let failed = await operation.value
    XCTAssertNil(failed)
    XCTAssertEqual(store.library.managedWorktrees.first?.pendingForkSourceTaskID, f.source.id)
    XCTAssertNil(store.library.tasks.first { $0.id == record.taskID }?.codexThreadID)
    XCTAssertFalse(store.codexTransport.isConnected(taskID: record.taskID))
    try FileManager.default.removeItem(at: workspace)
    XCTAssertTrue(store.saveLibrary())
    let result = await store.resumeWorktreeFork(record.taskID, openTask: false)
    XCTAssertEqual(result?.project, record.path, store.error ?? "")
    XCTAssertEqual(result?.codexThreadID, f.childThread)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: record.path).appendingPathComponent("setup-count")), "setup\n")
    await store.shutdown()
  }

  func testHistoricalWindowForkPreservesNewDraftUsesLocalNoticesAndLeavesMainNavigationUntouched() async throws {
    let f = try await fixture(), store = f.store
    let boundary = try XCTUnwrap(f.source.runIDs.first)
    let later = AgentRun(id: UUID().uuidString, kind: "chat", project: f.source.project,
      status: "succeeded", createdAt: 3, updatedAt: 4, request: .null,
      result: .object(["response": .string("later excluded reply"),
        "codex_thread_id": .string(try XCTUnwrap(f.source.codexThreadID)),
        "codex_turn_id": .string(UUID().uuidString)]))
    store.library.tasks[0].runIDs.append(later.id)
    store.library.chatRuns.append(later); store.runs.append(later)
    store.library.notes[later.id] = "later excluded prompt"
    store.draft = "/fork"
    let selection = store.selection, navigation = store.navigationBack
    let board = WorkspaceNotices()
    let operation = Task { try await store.forkTaskWindowConversation(f.source.id,
      through: boundary, consumeCommand: true, noticeBoard: board) }
    let request = try await waitUntilStarted(f)
    let boundaryRun = try XCTUnwrap(store.library.chatRuns.first { $0.id == boundary })
    XCTAssertEqual(request["forkOrigin"]["throughTurnId"].text,
      try XCTUnwrap(boundaryRun.result?["codex_turn_id"].text))
    XCTAssertFalse(store.canForkTaskWindow(f.source.id, through: boundary))
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertEqual(board.items.first?.level, .pending)
    store.draft = "new input while native fork is pending"
    try Data().write(to: f.release)
    let fork = try await operation.value
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).map(\.content), ["source prompt", "reply"])
    XCTAssertEqual(store.taskWindowDraft(f.source.id), "new input while native fork is pending")
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.selection, selection)
    XCTAssertEqual(store.navigationBack, navigation)
    XCTAssertEqual(fork.codexThreadID, f.childThread)
    XCTAssertTrue(board.items.isEmpty)
    XCTAssertTrue(store.notices.items.isEmpty)
    await store.shutdown()
  }

  func testMainRequestCapturesCommandBeforeSchedulingAndKeepsInputEnteredBeforeCreation() async throws {
    let f = try await fixture(), store = f.store
    store.draft = "/fork"
    let operation = try XCTUnwrap(store.requestConversationFork(consumeCommand: true))
    store.draft = "new input before the fork task starts"
    _ = try await waitUntilStarted(f)
    try Data().write(to: f.release)
    let result = await operation.value
    let fork = try XCTUnwrap(result)
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.taskWindowDraft(f.source.id), "new input before the fork task starts")
    XCTAssertEqual(store.navigationBack.last?.run, f.source.selectionID)
    XCTAssertEqual(fork.codexThreadID, f.childThread)
    XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
    await store.shutdown()
  }

  func testMainHistoricalActionCanForkLoadedPrefixWhenLaterHistoryIsUnavailable() async throws {
    let f = try await fixture(), store = f.store
    let boundary = try XCTUnwrap(f.source.runIDs.first)
    store.library.tasks[0].runIDs.append("not-loaded-later-run")
    XCTAssertFalse(store.canForkConversation, "The latest-history menu must remain unavailable")
    XCTAssertTrue(store.canForkConversation(through: boundary))
    XCTAssertFalse(store.canForkConversation(through: "foreign-run"))
    let operation = try XCTUnwrap(store.requestConversationFork(through: boundary))
    let request = try await waitUntilStarted(f)
    let boundaryRun = try XCTUnwrap(store.library.chatRuns.first { $0.id == boundary })
    XCTAssertEqual(request["forkOrigin"]["throughTurnId"].text, boundaryRun.result?["codex_turn_id"].text)
    try Data().write(to: f.release)
    let result = await operation.value
    let fork = try XCTUnwrap(result)
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertEqual(fork.codexThreadID, f.childThread)
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.taskWindowDraft(f.source.id), "keep current draft")
    XCTAssertEqual(store.library.tasks.first { $0.id == f.source.id }?.runIDs,
      [boundary, "not-loaded-later-run"])
    XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
    await store.shutdown()
  }

  func testScheduledMainForkDoesNotCreateFromNewlySelectedUnrelatedChat() async throws {
    let f = try await fixture(), store = f.store
    let other = WorkspaceTask(id: UUID().uuidString, project: f.source.project, title: "Other", runIDs: [])
    store.library.tasks.append(other)
    store.draft = "/fork"
    let operation = try XCTUnwrap(store.requestConversationFork(consumeCommand: true))
    store.selectTask(other)
    store.draft = "other draft"
    let result = await operation.value
    XCTAssertNil(result)
    XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id, other.id])
    XCTAssertEqual(store.selectedTask?.id, other.id)
    XCTAssertEqual(store.draft, "other draft")
    XCTAssertEqual(store.taskWindowDraft(f.source.id), "/fork")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.started.path))
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertNil(store.error)
    await store.shutdown()
  }

  func testSlashCommandWaitsForNativeCreationBeforeOpeningChildWithoutModelSubmission() async throws {
    let f = try await fixture(), store = f.store
    store.draft = "/fork"
    XCTAssertTrue(store.handleComposerCommand())
    _ = try await waitUntilStarted(f)
    XCTAssertEqual(store.selectedTask?.id, f.source.id)
    XCTAssertEqual(store.draft, "/fork")
    XCTAssertEqual(store.library.tasks.count, 1)
    try Data().write(to: f.release)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.tasks.count == 1 || store.taskMenuForkingID != nil {
      guard ContinuousClock.now < deadline else {
        XCTFail("Slash fork did not publish its acknowledged child")
        await store.shutdown()
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let fork = try XCTUnwrap(store.selectedTask)
    XCTAssertNotEqual(fork.id, f.source.id)
    XCTAssertEqual(fork.codexThreadID, f.childThread)
    XCTAssertEqual(store.taskWindowDraft(f.source.id), "")
    XCTAssertTrue(store.codexTransport.isConnected(taskID: fork.id))
    XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
    XCTAssertTrue(store.notices.items.isEmpty)
    await store.shutdown()
  }

  func testCancelledBeforeSchedulingPublishesNeitherNativeNorTextChildAndKeepsCommand() async throws {
    for native in [true, false] {
      let f = try await fixture(), store = f.store
      if !native {
        var config = store.modelConfiguration(for: f.source.id)
        config.apiProtocol = .chatCompletions
        try store.saveModelConfiguration(config)
      }
      store.draft = "/fork"
      let board = WorkspaceNotices()
      let operation = Task { try await store.forkTaskWindowConversation(f.source.id,
        consumeCommand: true, noticeBoard: board) }
      operation.cancel()
      do { _ = try await operation.value; XCTFail("A pre-cancelled window action must not publish") }
      catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id])
      XCTAssertEqual(store.draft, "/fork")
      XCTAssertNil(store.taskMenuForkingID)
      XCTAssertTrue(board.items.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.started.path))
      await store.shutdown()
    }
  }

  func testUnavailableSlashCommandReportsReasonWithoutClearingDraftOrSendingToModel() async throws {
    let f = try await fixture(), store = f.store
    store.library.tasks[0].runIDs = []
    store.draft = "/fork"
    XCTAssertTrue(store.handleComposerCommand())
    XCTAssertNotNil(store.error)
    XCTAssertEqual(store.draft, "/fork")
    XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id])
    XCTAssertNil(store.taskMenuForkingID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.started.path))
    await store.shutdown()
  }

  func testNativeCommandIsConsumedOnlyAfterSaveAndCancellationPreservesItInCallingWindow() async throws {
    for outcome in ["success", "cancel", "save-failure"] {
      let f = try await fixture(), store = f.store
      let board = WorkspaceNotices()
      store.draft = "/fork"
      let operation = Task { try await store.forkTaskWindowConversation(f.source.id,
        consumeCommand: true, noticeBoard: board) }
      _ = try await waitUntilStarted(f)
      XCTAssertEqual(store.draft, "/fork")
      if outcome == "cancel" { operation.cancel() }
      if outcome == "save-failure" {
        let file = store.dataRoot.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
      }
      try Data().write(to: f.release)
      do {
        let fork = try await operation.value
        XCTAssertEqual(outcome, "success")
        XCTAssertEqual(fork.codexThreadID, f.childThread)
        XCTAssertEqual(store.draft, "")
      } catch {
        XCTAssertNotEqual(outcome, "success", error.localizedDescription)
        XCTAssertEqual(store.draft, "/fork")
        XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id])
        if outcome == "cancel" { XCTAssertTrue(error is CancellationError); XCTAssertTrue(board.items.isEmpty) }
        else { XCTAssertEqual(board.items.first?.title, "创建聊天分支失败") }
      }
      XCTAssertTrue(store.notices.items.isEmpty)
      XCTAssertFalse(board.items.contains { $0.level == .pending })
      XCTAssertEqual(store.selectedTask?.id, f.source.id)
      await store.shutdown()
    }
  }

  func testPendingForkPreservesLatestLibraryAndPublishesOnlyAcknowledgedIndependentThread() async throws {
    for projectless in [false, true] {
      let f = try await fixture(projectless: projectless), store = f.store
      let operation = Task { await store.forkTaskFromMenu(f.source.id) }
      let request = try await waitUntilStarted(f)
      let childID = try XCTUnwrap(request["taskId"].text)
      XCTAssertEqual(request["resumeOnly"].boolean, false)
      XCTAssertEqual(request["forkOrigin"]["threadId"].text, f.source.codexThreadID)
      XCTAssertNotEqual(childID, f.source.id)
      XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id])
      XCTAssertEqual(store.selectedTask?.id, f.source.id)
      XCTAssertFalse(store.canForkTaskFromMenu(f.source.id))
      XCTAssertEqual(store.notices.items.first?.title, "正在创建聊天分支…")
      XCTAssertEqual(store.notices.items.first?.level, .pending)
      store.library.notes["unrelated-update"] = "changed during native creation"
      store.library.drafts["another-chat"] = "late draft"
      store.library.tasks[0].title = "renamed while pending"
      try Data().write(to: f.release)
      let result = await operation.value
      let fork = try XCTUnwrap(result)
      XCTAssertEqual(fork.codexThreadID, f.childThread)
      XCTAssertEqual(fork.title, f.source.title, "Keep the full title captured at the fork boundary")
      XCTAssertEqual(store.library.tasks.first { $0.id == f.source.id }?.title, "renamed while pending")
      XCTAssertEqual(store.library.notes["unrelated-update"], "changed during native creation")
      XCTAssertEqual(store.library.drafts["another-chat"], "late draft")
      XCTAssertEqual(store.library.drafts[f.source.id], "keep current draft")
      XCTAssertTrue(store.codexTransport.isConnected(taskID: fork.id))
      XCTAssertNil(store.codexTransport.turnToken(taskID: fork.id))
      XCTAssertFalse(try events(f).contains { $0["method"].text == "codex.turn.submit" })
      XCTAssertFalse(store.notices.items.contains { $0.level == .pending })
      let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(saved.tasks.first?.codexThreadID, f.childThread)
      if projectless {
        XCTAssertEqual(saved.projectlessTaskDirectories[fork.id], request["project"].text)
        XCTAssertEqual(fork.codexWorkspacePath, request["project"].text)
      }
      await store.shutdown()
    }
  }

  func testNativeFailureOrInvalidAcknowledgmentDoesNotFallBackToTextAndAllowsRetry() async throws {
    for mode in ["error", "not-forked", "resumed", "invalid-id"] {
      let f = try await fixture(mode: mode), store = f.store
      let operation = Task { await store.forkTaskFromMenu(f.source.id) }
      let request = try await waitUntilStarted(f)
      try Data().write(to: f.release)
      let result = await operation.value
      XCTAssertNil(result, mode)
      XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id], mode)
      XCTAssertTrue(store.library.forkRuns.isEmpty, mode)
      XCTAssertEqual(store.selectedTask?.id, f.source.id, mode)
      XCTAssertEqual(store.draft, "keep current draft", mode)
      XCTAssertFalse(store.codexTransport.isConnected(taskID: try XCTUnwrap(request["taskId"].text)), mode)
      XCTAssertTrue(store.canForkTaskFromMenu(f.source.id), mode)
      XCTAssertFalse(store.notices.items.contains { $0.level == .pending }, mode)
      XCTAssertEqual(store.notices.items.first?.title, "创建聊天分支失败", mode)
      let trace = try events(f)
      XCTAssertFalse(trace.contains { $0["method"].text == "codex.turn.submit" }, mode)
      if mode != "error" { XCTAssertTrue(trace.contains { $0["method"].text == "codex.thread.stop" }, mode) }
      await store.shutdown()
    }
  }

  func testCancelledStaleOrUnsavedForkStopsOnlyItsUnpublishedChild() async throws {
    for condition in ["cancel", "archive", "move", "save-failure"] {
      let f = try await fixture(), store = f.store
      let operation = Task { await store.forkTaskFromMenu(f.source.id) }
      let request = try await waitUntilStarted(f)
      let childID = try XCTUnwrap(request["taskId"].text)
      switch condition {
      case "cancel": operation.cancel()
      case "archive": store.library.tasks[0].archived = true
      case "move": store.library.tasks[0].project += "/changed"
      default:
        let file = store.dataRoot.appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
      }
      try Data().write(to: f.release)
      let result = await operation.value
      XCTAssertNil(result, condition)
      XCTAssertEqual(store.library.tasks.map(\.id), [f.source.id], condition)
      XCTAssertTrue(store.library.forkRuns.isEmpty, condition)
      XCTAssertFalse(store.codexTransport.isConnected(taskID: childID), condition)
      XCTAssertFalse(store.notices.items.contains { $0.level == .pending }, condition)
      let stops = try events(f).filter { $0["method"].text == "codex.thread.stop" }
      XCTAssertEqual(stops.map { $0["taskId"].text }, [childID], condition)
      if condition == "cancel" { XCTAssertNil(store.error) }
      await store.shutdown()
    }
  }
}
