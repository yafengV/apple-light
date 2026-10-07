import XCTest
@testable import ShipiOS

final class SubagentCloseIntegrationTests: XCTestCase {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("closed-child-\(UUID())")
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent_close_server.py").path]
    server.environment = ProcessInfo.processInfo.environment.merging([
      "SHIPIOS_CLOSED_CHILD_LOG": root.appendingPathComponent("requests.jsonl").path]) { _, new in new }
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Closed child fixture did not start") }
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
  @MainActor private func waitFor(_ explanation: String, _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition() {
      guard ContinuousClock.now < end else { throw AgentFailure(message: "Closed child lifecycle timed out: \(explanation); fixture trace: \((try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8))?.suffix(3000) ?? "missing")") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  @MainActor private func turn(_ text: String, in store: WorkspaceStore) async throws -> String {
    let started = await store.startChat(text)
    let run = try XCTUnwrap(started, store.error ?? "Missing parent run")
    try await waitFor("parent turn " + text) { store.library.chatRuns.first { $0.id == run }?.isActive == false }
    await store.modelTask(runID: run)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "succeeded", store.error ?? "")
    return run
  }
  private func requests() throws -> [JSONValue] {
    try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
      .split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
  }
  @MainActor func testActualCloseRemainsClosedAcrossColdHistoryNavigationAndRejectsAutomaticReload() async throws {
    let original = try await store()
    let parentRun = try await turn("parent-spawn", in: original)
    let task = try XCTUnwrap(original.library.task(containing: parentRun)?.id)
    try await waitFor("spawned child completion") { original.subagents(taskID: task).first?.status == .completed }
    let child = try XCTUnwrap(original.subagents(taskID: task).first)
    let closeRun = try await turn("parent-close:" + child.threadID, in: original)
    XCTAssertEqual(original.library.chatRuns.first { $0.id == closeRun }?.result?["response"].text, "Parent closed child")
    XCTAssertTrue(try requests().contains { $0["item"]["name"].text == "close_agent" })
    try await waitFor("closed child unloaded") { original.subagents(taskID: task).first { $0.id == child.id }?.loaded == false }
    let closed = try XCTUnwrap(original.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertEqual(closed.status, .shutdown, "A native close must not be displayed as an ordinary cold completed thread")
    XCTAssertFalse(closed.acceptsInput)
    try await original.prepareSubagent(taskID: task, agent: child)
    XCTAssertFalse(original.subagents(taskID: task).first { $0.id == child.id }?.loaded ?? true, "A stale detail selection cannot reopen the newly closed thread")
    await original.shutdown()
    let restored = try await store()
    let cold = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    let before = try requests().count
    try await restored.prepareSubagent(taskID: task, agent: cold)
    let events = try await restored.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertTrue(SubagentTranscript(events: events).entries.contains { $0.text == "Native child history remains readable" })
    let after = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertEqual(after.status, .shutdown); XCTAssertFalse(after.loaded); XCTAssertFalse(after.acceptsInput)
    do {
      _ = try await restored.codexTransport.loadSubagent(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
      XCTFail("Automatic detail loading reopened an explicitly closed child")
    } catch { XCTAssertTrue(error.localizedDescription.contains("closed"), error.localizedDescription) }
    XCTAssertEqual(try requests().count, before, "History navigation must not submit a model request")
  }
  @MainActor func testClosingOneTasksChildDoesNotCloseOrReloadAnotherTasksChild() async throws {
    let store = try await store()
    let run = try await turn("parent-spawn", in: store)
    let task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor("first child completed") { store.subagents(taskID: task).first?.status == .completed }
    let child = try XCTUnwrap(store.subagents(taskID: task).first)
    store.newTask()
    let peerRun = try await turn("parent-spawn", in: store)
    let peerTask = try XCTUnwrap(store.library.task(containing: peerRun)?.id)
    XCTAssertNotEqual(task, peerTask)
    try await waitFor("peer child completed") { store.subagents(taskID: peerTask).first?.status == .completed }
    let peer = try XCTUnwrap(store.subagents(taskID: peerTask).first)
    let selected = await store.selectTaskAwaitingScope(try XCTUnwrap(store.library.tasks.first { $0.id == task }))
    XCTAssertTrue(selected)
    _ = try await turn("parent-close:" + child.threadID, in: store)
    try await waitFor("closed child released") { store.subagents(taskID: task).first?.loaded == false }
    XCTAssertEqual(store.subagents(taskID: task).first?.status, .shutdown)
    let stillOpen = try XCTUnwrap(store.subagents(taskID: peerTask).first)
    XCTAssertEqual(stillOpen.id, peer.id); XCTAssertTrue(stillOpen.acceptsInput)
    XCTAssertEqual(stillOpen.status, .completed)
    let before = try requests().count
    try await store.prepareSubagent(taskID: peerTask, agent: stillOpen)
    XCTAssertEqual(try requests().count, before)
    XCTAssertTrue(store.subagents(taskID: peerTask).first?.acceptsInput == true)
  }
}
