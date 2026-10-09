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
              with open(os.path.join(root, 'started.tmp'), 'w') as out:
                  json.dump({'taskId': params['taskId'], 'resumeOnly': params['resumeOnly'],
                             'forkOrigin': params['forkOrigin'], 'project': project}, out)
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

  private func events(_ fixture: Fixture) throws -> [JSONValue] {
    try String(contentsOf: fixture.trace).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
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
