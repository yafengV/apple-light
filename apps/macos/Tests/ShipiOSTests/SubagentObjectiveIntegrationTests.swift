import XCTest
@testable import ShipiOS

final class SubagentObjectiveIntegrationTests: XCTestCase {
  @MainActor func testDelegatedObjectiveSurvivesCompletionColdDiscoveryAndChildRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-objective-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = root.appendingPathComponent("gate")
    try Data().write(to: gate)
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent_states_server.py").path]
    server.environment = ProcessInfo.processInfo.environment.merging([
      "PYTHONUNBUFFERED": "1", "SHIPIOS_CHILD_STATES_GATE": gate.path,
      "SHIPIOS_CHILD_STATES_LOG": root.appendingPathComponent("requests.jsonl").path]) { _, new in new }
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    func makeStore() async throws -> WorkspaceStore {
      let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
      await store.restore(); await store.openProjectless()
      var config = ModelConfiguration(); config.apiProtocol = .codexResponses
      config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "gpt-5.4"
      try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
      addTeardownBlock { await store.shutdown() }
      return store
    }
    func waitFor(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(20))
      while !condition() {
        guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Objective discovery timed out") }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    func objective(_ row: CodexSubagent) throws -> String? {
      let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(row))
      return value["objective"].text
    }
    let original = try await makeStore()
    let started = await original.startChat("state-parent-interrupt")
    let run = try XCTUnwrap(started), task = try XCTUnwrap(original.library.task(containing: run)?.id)
    await original.modelTask(runID: run)?.value
    try await waitFor { original.subagents(taskID: task).first?.status == .completed }
    let child = try XCTUnwrap(original.subagents(taskID: task).first)
    XCTAssertEqual(try objective(child), "state-child-hold", "The delegated prompt must not be replaced by the parent's prompt or child's final reply")
    XCTAssertEqual(child.preview, "Late child response")
    let parents = original.library.tasks.first { $0.id == task }?.runIDs
    let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").count
    await original.shutdown()
    let index = try XCTUnwrap(original.library.tasks.firstIndex { $0.id == task })
    original.library.tasks[index].codexSubagents = []; original.saveLibrary()
    let restored = try await makeStore()
    try await restored.refreshSubagents(taskID: task, expectedRoot: child.rootThreadID)
    try await waitFor { !restored.subagents(taskID: task).isEmpty }
    let cold = try XCTUnwrap(restored.subagents(taskID: task).first)
    XCTAssertFalse(cold.loaded); XCTAssertEqual(try objective(cold), "state-child-hold")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").count, requests)
    try await restored.prepareSubagent(taskID: task, agent: cold)
    _ = try await restored.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "state-child-retry", expectedTurnID: nil)
    try await waitFor { restored.subagents(taskID: task).first?.preview == "Child recovered on the same thread" }
    let retried = try XCTUnwrap(restored.subagents(taskID: task).first)
    XCTAssertEqual(try objective(retried), "state-child-hold")
    XCTAssertEqual(retried.id, child.id)
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.runIDs, parents)
    await restored.shutdown()
  }
}
