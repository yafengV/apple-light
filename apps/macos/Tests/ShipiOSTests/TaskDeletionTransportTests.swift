import XCTest
@testable import ShipiOS

final class TaskDeletionTransportTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  override func setUpWithError() throws {
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server.arguments = ["-u", fixture.path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Local fixture could not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
  }

  @MainActor private func checkDeletion(_ api: ModelAPIProtocol) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-stream-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = endpoint; config.apiProtocol = api
    config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let started = await store.startChat(api == .codexResponses ? "activity-archive-stream" : "slow-first")
    let runID = try XCTUnwrap(started, store.error ?? "No run")
    let owner = try XCTUnwrap(store.library.task(containing: runID)?.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.isEmpty != false {
      guard ContinuousClock.now < deadline else {
        XCTFail("No actual streamed response before deletion")
        await store.shutdown(); return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    store.newTask()
    let otherStarted = await store.startChat(api == .codexResponses ? "activity-archive-stream other" : "slow-other")
    let otherRunID = try XCTUnwrap(otherStarted, store.error ?? "No parallel run")
    let otherOwner = try XCTUnwrap(store.library.task(containing: otherRunID)?.id)
    let otherRequest = try XCTUnwrap(store.modelTask(runID: otherRunID))
    store.draft = "keep current draft"
    store.library.queuedMessages = [.init(taskID: owner, text: "delete queue"),
      .init(taskID: otherOwner, text: "keep queue")]
    store.toggleActivity()
    store.requestTaskDeletion(owner)
    let request = try XCTUnwrap(store.archiveDeletion)
    let operation = Task { await store.confirmArchiveDeletion(requestID: request.id) }
    while !store.deletingArchive && store.archiveDeletion != nil { await Task.yield() }
    XCTAssertFalse(store.canStartChat(taskID: owner))
    let duplicate = Task { await store.confirmArchiveDeletion(requestID: request.id) }
    store.dismissArchiveDeletion(requestID: request.id)
    XCTAssertNotNil(store.archiveDeletion)
    await operation.value
    await duplicate.value
    XCTAssertNil(store.archiveDeletion, store.archivedTaskDeletionError ?? "")
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertNil(store.modelTask(runID: runID))
    XCTAssertFalse(store.library.tasks.contains { $0.id == owner })
    XCTAssertFalse(store.library.chatRuns.contains { $0.id == runID })
    XCTAssertEqual(store.library.queuedMessages.map(\.taskID), [otherOwner])
    XCTAssertEqual(store.selectedTask?.id, otherOwner)
    XCTAssertEqual(store.draft, "keep current draft")
    XCTAssertEqual(store.activeChatRun(taskID: otherOwner)?.id, otherRunID)
    XCTAssertNotNil(store.modelTask(runID: otherRunID))
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(saved.deletedRunIDs.contains(runID))
    XCTAssertFalse(saved.tasks.contains { $0.id == owner })
    XCTAssertFalse(saved.tasks.first(where: { $0.id == otherOwner })?.archived ?? true)
    await store.cancel(taskID: otherOwner)
    await otherRequest.value
    await store.shutdown()
  }
  @MainActor func testBasicDeletionStopsOnlyTargetActualStream() async throws {
    try await checkDeletion(.chatCompletions)
  }
  @MainActor func testCoreDeletionStopsOnlyTargetActualStream() async throws {
    try await checkDeletion(.codexResponses)
  }
}
