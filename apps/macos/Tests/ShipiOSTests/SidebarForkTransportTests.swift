import XCTest
@testable import ShipiOS

final class SidebarForkTransportTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  private var trace = FileManager.default.temporaryDirectory.appendingPathComponent("fork-trace-\(UUID()).jsonl")
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    var environment = ProcessInfo.processInfo.environment
    environment["FIXTURE_EVENT_LOG"] = trace.path
    server.environment = environment
    let pipe = Pipe()
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: trace)
  }

  @MainActor private func checkFork(_ api: ModelAPIProtocol) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-fork-stream-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = endpoint; config.apiProtocol = api
    config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let sourceID = UUID().uuidString
    let finished = AgentRun(id: "finished", kind: "chat", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 2, request: .null,
      result: .object(["response": .string("finished source reply")]))
    store.library.tasks = [.init(id: sourceID, project: "", title: "Source", runIDs: [finished.id])]
    store.library.chatRuns = [finished]
    store.library.notes[finished.id] = "finished source prompt"
    store.selectTask(store.library.tasks[0])
    store.draft = "keep source draft"
    let started = await store.startChat(api == .codexResponses ? "activity-archive-stream" : "slow-first")
    let activeID = try XCTUnwrap(started, store.error ?? "No parent run")
    let sourceRequest = try XCTUnwrap(store.modelTask(runID: activeID))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.first(where: { $0.id == activeID })?.result?["response"].text?.isEmpty != false {
      guard ContinuousClock.now < deadline else {
        let phases = (try? String(contentsOf: trace)) ?? "No fixture requests"
        let run = store.library.chatRuns.first { $0.id == activeID }
        XCTFail("No actual source stream before fork: \(run?.status ?? "missing") \(run?.result?.pretty ?? "")\n\(phases)")
        await store.shutdown(); return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let sourceThread = store.library.tasks.first { $0.id == sourceID }?.codexThreadID
    let created = await store.forkTaskFromMenu(sourceID)
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertNil(fork.codexThreadID, "A new task must not resume the parent's Core thread")
    let followup = await store.startChat(api == .codexResponses ? "skill-dependency-request-echo" : "context")
    let childID = try XCTUnwrap(followup, store.error ?? "No child run")
    try await XCTUnwrap(store.modelTask(runID: childID)).value
    let child = try XCTUnwrap(store.library.chatRuns.first { $0.id == childID })
    XCTAssertEqual(child.status, "succeeded", store.error ?? "")
    let response = try XCTUnwrap(child.result?["response"].text)
    if api == .chatCompletions {
      let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(response.utf8))
      XCTAssertEqual(messages.filter { $0.role != "system" }.map(\.content),
        ["finished source prompt", "finished source reply", "context"])
      XCTAssertFalse(response.contains("slow-first"))
    } else {
      let body = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
      XCTAssertTrue(body.pretty.contains("finished source prompt"))
      XCTAssertTrue(body.pretty.contains("finished source reply"))
      XCTAssertFalse(body.pretty.contains("activity-archive-stream"))
      let childThread = store.library.tasks.first { $0.id == fork.id }?.codexThreadID
      XCTAssertNotNil(sourceThread)
      XCTAssertNotNil(childThread)
      XCTAssertNotEqual(sourceThread, childThread)
    }
    XCTAssertEqual(store.activeRun(taskID: sourceID)?.id, activeID)
    XCTAssertNotNil(store.modelTask(runID: activeID))
    XCTAssertEqual(store.library.drafts[sourceID], "keep source draft")
    XCTAssertEqual(store.library.tasks.first { $0.id == sourceID }?.runIDs, [finished.id, activeID])
    XCTAssertEqual(store.library.tasks.first { $0.id == fork.id }?.runIDs, fork.runIDs + [childID])
    await store.cancel(taskID: sourceID)
    await sourceRequest.value
    await store.shutdown()
  }
  @MainActor func testBasicSidebarForkContinuesOnlyCompletedHistoryWhileParentRuns() async throws {
    try await checkFork(.chatCompletions)
  }
  @MainActor func testCoreSidebarForkUsesIndependentThreadWhileParentRuns() async throws {
    try await checkFork(.codexResponses)
  }
}
