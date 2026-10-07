import XCTest
@testable import ShipiOS

final class SubagentTerminalPresentationIntegrationTests: XCTestCase {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-states-\(UUID())")
  private var server: Process!
  private var endpoint = ""
  private var gate: URL { root.appendingPathComponent("gate") }
  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent_states_server.py").path]
    server.environment = ProcessInfo.processInfo.environment.merging([
      "PYTHONUNBUFFERED": "1", "SHIPIOS_CHILD_STATES_GATE": gate.path,
      "SHIPIOS_CHILD_STATES_LOG": root.appendingPathComponent("requests.jsonl").path]) { _, new in new }
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Child states fixture did not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }
  @MainActor private func store() async throws -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses; config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    addTeardownBlock { await store.shutdown() }
    return store
  }
  @MainActor private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Child presentation timed out: " + message) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  @MainActor func testActualFailureLeavesOverviewButPreservesDraftAndRecoversOnSameChild() async throws {
    try await verifyTerminal(failure: true)
  }
  @MainActor func testActualInterruptionLeavesOverviewButPreservesDraftAndRecoversOnSameChild() async throws {
    try await verifyTerminal(failure: false)
  }
  @MainActor func testFailedColdHistoryRemainsHiddenAndItsSavedDraftCanRecoverSameChild() async throws {
    try await verifyTerminal(failure: true, restart: true)
  }
  @MainActor func testOverviewReconnectionRecoversColdHistoryWithoutUIRowsOrLoadingChild() async throws {
    let original = try await store()
    try Data().write(to: gate)
    let started = await original.startChat("state-parent-failure")
    let run = try XCTUnwrap(started), task = try XCTUnwrap(original.library.task(containing: run)?.id)
    try await waitFor("actual child failure") { original.subagents(taskID: task).first?.status == .failed }
    await original.modelTask(runID: run)?.value
    let child = try XCTUnwrap(original.subagents(taskID: task).first)
    let detail = SubagentDetailState(); detail.bindDrafts(to: original, taskID: task); detail.select(child)
    detail.draft = "state-child-retry 保留发现草稿🙂"
    let parents = original.library.tasks.first { $0.id == task }?.runIDs
    let requestsBefore = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").count
    await original.shutdown()
    // Simulate an absent presentation cache. Native durable history, ownership,
    // resume contract and the independently persisted child draft stay intact.
    let index = try XCTUnwrap(original.library.tasks.firstIndex { $0.id == task })
    original.library.tasks[index].codexSubagents = []; original.saveLibrary()
    let restored = try await store()
    XCTAssertTrue(restored.subagents(taskID: task).isEmpty)
    do {
      try await restored.refreshSubagents(taskID: task, expectedRoot: UUID().uuidString)
      XCTFail("A stale root must not connect or reconcile another thread")
    } catch { XCTAssertTrue(restored.subagents(taskID: task).isEmpty) }
    try await restored.refreshSubagents(taskID: task, expectedRoot: child.rootThreadID)
    try await waitFor("cold discovery arrives without selecting a child") { !restored.subagents(taskID: task).isEmpty }
    let cold = try XCTUnwrap(restored.subagents(taskID: task).first)
    XCTAssertEqual(cold.id, child.id); XCTAssertEqual(cold.status, .failed)
    XCTAssertFalse(cold.loaded); XCTAssertFalse(cold.working); XCTAssertFalse(cold.acceptsInput)
    XCTAssertEqual(cold.nickname, child.nickname); XCTAssertEqual(cold.model, child.model)
    XCTAssertEqual(cold.parentThreadID, child.parentThreadID); XCTAssertEqual(cold.depth, child.depth)
    XCTAssertNotNil(cold.recencyAtMs)
    XCTAssertTrue(SubagentOverview([cold]).visible.isEmpty)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").count, requestsBefore, "Discovery must not submit a model message")
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.runIDs, parents)
    try await restored.prepareSubagent(taskID: task, agent: cold)
    let ready = try XCTUnwrap(restored.subagents(taskID: task).first)
    XCTAssertTrue(ready.acceptsInput)
    detail.bindDrafts(to: restored, taskID: task); detail.update(ready)
    XCTAssertEqual(detail.draft, "state-child-retry 保留发现草稿🙂")
    let sent = await detail.sendMessage(working: ready.working) { agent, message, expectedTurn in
      try await restored.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: message.content, expectedTurnID: expectedTurn)
    }
    XCTAssertTrue(sent)
    let accepted = try XCTUnwrap(restored.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID).last?.turnID)
    try await waitFor("discovered child completes same-thread retry") {
      restored.subagentLiveStates[child.id]?.events.contains {
        $0["type"].text == "task_complete" && $0["turn_id"].text == accepted
      } == true && restored.subagents(taskID: task).first?.status == .completed
    }
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.runIDs, parents)
    XCTAssertFalse(detail.hasInput)
  }
  @MainActor private func verifyTerminal(failure: Bool, restart: Bool = false) async throws {
    var store = try await store()
    let started = await store.startChat(failure ? "state-parent-failure" : "state-parent-interrupt")
    let run = try XCTUnwrap(started), task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor("parent finished, child still running") {
      store.library.chatRuns.first { $0.id == run }?.isActive == false && store.subagents(taskID: task).first?.status == .running
    }
    await store.modelTask(runID: run)?.value
    let child = try XCTUnwrap(store.subagents(taskID: task).first)
    let detail = SubagentDetailState(); detail.bindDrafts(to: store, taskID: task); detail.select(child)
    detail.draft = "state-child-retry-blocked 保留终态草稿🙂"
    XCTAssertEqual(SubagentOverview(store.subagents(taskID: task)).active.map(\.id), [child.id])
    let events = try await store.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let turn = try XCTUnwrap(SubagentTranscript(events: events).activeTurnID)
    if failure { try Data().write(to: gate) }
    else { await store.stopSubagent(taskID: task, agent: child, expectedTurnID: turn) }
    let terminalStatus: CodexSubagentStatus = failure ? .failed : .interrupted
    try await waitFor("native terminal status") { store.subagents(taskID: task).first?.status == terminalStatus }
    let terminal = try XCTUnwrap(store.subagents(taskID: task).first)
    let overview = SubagentOverview(store.subagents(taskID: task))
    XCTAssertTrue(overview.visible.isEmpty); XCTAssertTrue(overview.active.isEmpty); XCTAssertTrue(overview.done.isEmpty)
    XCTAssertEqual(store.subagents(taskID: task).count, 1, "Filtering must not delete the child's persistent record")
    XCTAssertTrue(terminal.acceptsInput); XCTAssertFalse(terminal.working)
    detail.update(terminal)
    XCTAssertEqual(detail.draft, "state-child-retry-blocked 保留终态草稿🙂")
    let history = try await store.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertFalse(history.isEmpty)
    let parents = store.library.tasks.first { $0.id == task }?.runIDs
    if restart {
      await store.shutdown()
      store = try await self.store()
      let selected = await store.selectTaskAwaitingScope(try XCTUnwrap(store.library.tasks.first { $0.id == task }))
      XCTAssertTrue(selected)
      let cold = try XCTUnwrap(store.subagents(taskID: task).first)
      XCTAssertFalse(cold.loaded); XCTAssertEqual(cold.status, terminalStatus)
      XCTAssertTrue(SubagentOverview(store.subagents(taskID: task)).visible.isEmpty)
      try await store.prepareSubagent(taskID: task, agent: cold)
      let loaded = try XCTUnwrap(store.subagents(taskID: task).first)
      XCTAssertEqual(loaded.status, terminalStatus); XCTAssertTrue(loaded.acceptsInput)
      detail.bindDrafts(to: store, taskID: task); detail.update(loaded)
      XCTAssertEqual(detail.draft, "state-child-retry-blocked 保留终态草稿🙂")
    }
    let sent = await detail.sendMessage(working: terminal.working) { agent, message, expectedTurn in
      try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: message.content, expectedTurnID: expectedTurn)
    }
    XCTAssertTrue(sent, detail.error ?? "Missing retry input")
    let accepted = try XCTUnwrap(store.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID).last?.turnID)
    try await waitFor("retry is active despite its old failed or interrupted history") {
      store.subagents(taskID: task).first?.status == .running
    }
    XCTAssertEqual(SubagentOverview(store.subagents(taskID: task)).active.map(\.id), [child.id])
    XCTAssertTrue(SubagentOverview(store.subagents(taskID: task)).done.isEmpty)
    try Data().write(to: gate.deletingPathExtension().appendingPathExtension("retry"))
    try await waitFor("retry actual turn completes") {
      store.subagentLiveStates[child.id]?.events.contains {
        $0["type"].text == "task_complete" && $0["turn_id"].text == accepted
      } == true && store.subagents(taskID: task).first?.status == .completed
    }
    XCTAssertEqual(SubagentOverview(store.subagents(taskID: task)).done.map(\.id), [child.id])
    XCTAssertEqual(store.library.tasks.first { $0.id == task }?.runIDs, parents)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished independently")
    let recovered = try await store.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertTrue(SubagentTranscript(events: recovered).entries.contains { $0.text == "Child recovered on the same thread" })
    XCTAssertFalse(detail.hasInput)
  }
}
