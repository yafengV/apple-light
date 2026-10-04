import XCTest
@testable import ShipiOS

final class CodexSubagentIntegrationTests: XCTestCase {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-subagents-\(UUID())")
  private var server: Process!
  private var endpoint = ""

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent_server.py")
    server.arguments = ["-u", fixture.path]
    server.environment = ProcessInfo.processInfo.environment.merging([
      "SHIPIOS_SUBAGENT_COMPLETE_GATE": root.appendingPathComponent("complete-gate").path
    ]) { _, new in new }
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Subagent fixture failed to start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }

  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }

  @MainActor private func store() async throws -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses
    config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    addTeardownBlock { await store.shutdown() }
    return store
  }

  @MainActor private func waitFor(_ explanation: String, seconds: Int = 15,
    _ condition: () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
      guard ContinuousClock.now < end else { throw AgentFailure(message: explanation) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  @MainActor private func finishedParent(_ store: WorkspaceStore, text: String) async throws -> (String, String) {
    let started = await store.startChat(text)
    let runID = try XCTUnwrap(started, store.error ?? "Parent did not start")
    let owner = try XCTUnwrap(store.library.task(containing: runID)?.id)
    try await waitFor("Parent remained active: \(store.error ?? "")", seconds: 25) {
      store.library.chatRuns.first { $0.id == runID }?.isActive == false
    }
    await store.modelTask(runID: runID)?.value
    let run = try XCTUnwrap(store.library.chatRuns.first { $0.id == runID })
    XCTAssertEqual(run.status, "succeeded", store.error ?? "")
    XCTAssertEqual(run.result?["response"].text, "Parent finished while child continues")
    return (owner, runID)
  }

  @MainActor func testActualSpawnToolPublishesChildCompletionAfterParentStreamEnds() async throws {
    let store = try await store()
    let (owner, runID) = try await finishedParent(store, text: "subagent-parent-complete")
    try await waitFor("Native child was not reported while parent was idle") {
      store.activeSubagents(taskID: owner).count == 1
    }
    let child = try XCTUnwrap(store.activeSubagents(taskID: owner).first)
    XCTAssertNotNil(UUID(uuidString: child.threadID)); XCTAssertNotEqual(child.threadID, child.rootThreadID)
    XCTAssertEqual(store.stopTarget(taskID: owner), .descendants(taskID: owner,
      threadID: child.rootThreadID, childIDs: [child.threadID]))
    try Data().write(to: root.appendingPathComponent("complete-gate"))
    try await waitFor("Child completion was lost after root stream ended") {
      store.subagents(taskID: owner).contains { $0.threadID == child.threadID && $0.status == .completed }
    }
    XCTAssertTrue(store.activeSubagents(taskID: owner).isEmpty)
    XCTAssertNil(store.stopTarget(taskID: owner))
    XCTAssertEqual(store.subagents(taskID: owner).first?.preview, "Native child finished")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == runID }?.status, "succeeded")
    store.saveLibrary()
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.tasks.first { $0.id == owner }?.codexSubagents?.first?.status, .completed)
    XCTAssertFalse(saved.tasks.first { $0.id == owner }?.codexSubagents?.first?.loaded ?? true)
    await store.shutdown()
  }

  @MainActor func testIdleStopUsesActualDescendantsRPCAndPreservesParentReplyAndPeer() async throws {
    let store = try await store()
    let (owner, runID) = try await finishedParent(store, text: "subagent-parent-stop")
    try await waitFor("Native held child not reported") { store.activeSubagents(taskID: owner).count == 1 }
    let child = try XCTUnwrap(store.activeSubagents(taskID: owner).first)
    store.newTask()
    let peerStarted = await store.startChat("subagent-peer-hold")
    let peerRun = try XCTUnwrap(peerStarted)
    let peer = try XCTUnwrap(store.library.task(containing: peerRun)?.id)
    XCTAssertNotEqual(peer, owner)
    try await waitFor("Peer native thread not started") {
      store.library.chatRuns.first { $0.id == peerRun }?.result?["codex_turn_id"].text != nil
    }
    do {
      try await store.codexTransport.interruptDescendants(taskID: owner, expectedThreadID: UUID().uuidString)
      XCTFail("Changed root identity was accepted")
    } catch { XCTAssertTrue(error.localizedDescription.contains("identity")) }
    XCTAssertEqual(store.activeSubagents(taskID: owner).count, 1)
    await store.cancel(taskID: owner)
    try await waitFor("Idle Stop failed to interrupt real child") {
      store.subagents(taskID: owner).contains { $0.threadID == child.threadID && $0.status == .interrupted }
    }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == runID }?.status, "succeeded")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == peerRun }?.isActive, true)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == runID }?.result?["response"].text,
      "Parent finished while child continues")
    XCTAssertTrue(store.activeSubagents(taskID: owner).isEmpty)
    await store.cancel(taskID: peer)
    await store.modelTask(runID: peerRun)?.value
    await store.shutdown()
  }
}
