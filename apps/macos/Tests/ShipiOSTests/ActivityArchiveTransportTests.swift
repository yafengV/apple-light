import XCTest
@testable import ShipiOS

final class ActivityArchiveTransportTests: XCTestCase {
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

  private enum Surface { case activityBatch, activityRow, sidebar, command, taskWindow }
  @MainActor private func checkArchive(_ api: ModelAPIProtocol, surface: Surface = .activityBatch) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-transport-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = endpoint
    config.apiProtocol = api
    config.model = api == .codexResponses ? "gpt-5.4" : "fixture"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let prompt = api == .codexResponses ? "activity-archive-stream" : "slow-first"
    let started = await store.startChat(prompt)
    let runID = try XCTUnwrap(started, store.error ?? "No run")
    let owner = try XCTUnwrap(store.library.task(containing: runID)?.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while store.library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.isEmpty != false {
      guard ContinuousClock.now < deadline else {
        let run = store.library.chatRuns.first(where: { $0.id == runID })
        XCTFail("No actual streamed response: \(run?.status ?? "missing") \(run?.result?.pretty ?? "")")
        await store.shutdown()
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let queue = QueuedMessage(taskID: owner, text: "follow up")
    store.library.queuedMessages.append(queue)
    store.draft = "unsent draft"
    let windowID = surface == .taskWindow ? UUID().uuidString : nil
    switch surface {
    case .activityBatch: store.toggleActivity(); store.requestActivityArchive()
    case .activityRow: store.toggleActivity(); await store.archiveActivityTask(owner)
    case .sidebar: await store.archiveTask(owner)
    case .taskWindow: await store.archiveTask(owner, inWindow: windowID)
    case .command:
      XCTAssertTrue(store.commandEnabled("archive"))
      store.executeCommand("archive")
      let commandDeadline = ContinuousClock.now.advanced(by: .seconds(2))
      while store.activityArchiveRequest == nil {
        guard ContinuousClock.now < commandDeadline else { XCTFail("No archive confirmation"); return }
        await Task.yield()
      }
    }
    XCTAssertEqual(store.activityArchiveRequest?.scope, surface == .activityBatch ? .priority : .task)
    XCTAssertEqual(store.activityArchiveRequest?.presentationWindowID, windowID)
    if windowID != nil {
      XCTAssertNil(store.archiveConfirmation())
      await store.confirmTaskArchive()
      XCTAssertNotNil(store.archiveConfirmation(inWindow: windowID))
    }
    XCTAssertTrue(store.activityArchiveNeedsStop)
    store.newTask()
    let otherStarted = await store.startChat(api == .codexResponses ? "activity-archive-stream other" : "slow-other")
    let otherRunID = try XCTUnwrap(otherStarted, store.error ?? "No parallel run")
    let otherOwner = try XCTUnwrap(store.library.task(containing: otherRunID)?.id)
    let otherRequest = try XCTUnwrap(store.modelTask(runID: otherRunID))
    let operation = Task { await store.confirmTaskArchive(inWindow: windowID) }
    while !store.archivingActivity && store.activityArchiveRequest != nil { await Task.yield() }
    XCTAssertFalse(store.canStartChat(taskID: owner))
    let duplicate = Task { await store.confirmTaskArchive(inWindow: windowID) }
    store.dismissTaskArchive(inWindow: windowID)
    XCTAssertNotNil(store.activityArchiveRequest)
    await operation.value
    await duplicate.value
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, [owner])
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 0, store.activityError ?? "")
    XCTAssertEqual(store.library.chatRuns.first(where: { $0.id == runID })?.status, "cancelled")
    XCTAssertFalse(store.library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.isEmpty ?? true)
    XCTAssertNil(store.modelTask(runID: runID))
    XCTAssertEqual(store.library.queuedMessages, [queue])
    XCTAssertEqual(store.library.chatRuns.count, 2, "Stopping must not restart the queued message")
    XCTAssertEqual(store.library.drafts[owner], "unsent draft")
    XCTAssertEqual(store.activeChatRun(taskID: otherOwner)?.id, otherRunID)
    XCTAssertNotNil(store.modelTask(runID: otherRunID))
    XCTAssertFalse(store.library.tasks.first(where: { $0.id == otherOwner })?.archived ?? true)
    await store.cancel(taskID: otherOwner)
    await otherRequest.value
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .tasks.first(where: { $0.id == owner })?.archived, true)
    await store.shutdown()
  }

  @MainActor func testBasicChatArchiveStopsActualStreamAndPreservesQueue() async throws {
    try await checkArchive(.chatCompletions)
  }
  @MainActor func testCoreArchiveStopsActualStreamAndPreservesQueue() async throws {
    try await checkArchive(.codexResponses)
  }
  @MainActor func testBasicChatSingleRowArchiveStopsOnlyItsActualStream() async throws {
    try await checkArchive(.chatCompletions, surface: .activityRow)
  }
  @MainActor func testCoreSingleRowArchiveStopsOnlyItsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .activityRow)
  }

  @MainActor func testBasicChatOrdinarySidebarArchiveStopsActualStream() async throws {
    try await checkArchive(.chatCompletions, surface: .sidebar)
  }
  @MainActor func testCoreOrdinarySidebarArchiveStopsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .sidebar)
  }
  @MainActor func testBasicChatArchiveCommandStopsActualStream() async throws {
    try await checkArchive(.chatCompletions, surface: .command)
  }
  @MainActor func testCoreArchiveCommandStopsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .command)
  }
  @MainActor func testBasicChatTaskWindowArchiveStopsActualStream() async throws {
    try await checkArchive(.chatCompletions, surface: .taskWindow)
  }
  @MainActor func testCoreTaskWindowArchiveStopsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .taskWindow)
  }

}
