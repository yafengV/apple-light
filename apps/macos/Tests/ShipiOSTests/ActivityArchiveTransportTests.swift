import XCTest
@testable import ShipiOS

final class ActivityArchiveTransportTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  private var trace = FileManager.default.temporaryDirectory.appendingPathComponent("archive-core-phases-\(UUID()).jsonl")
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
    try? FileManager.default.removeItem(at: trace)
  }

  private enum Surface { case activityBatch, activityRow, sidebar, command, taskWindow }
  @MainActor private func checkArchive(_ api: ModelAPIProtocol, surface: Surface = .activityBatch,
    delayedAgentStartup: Bool = false) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-transport-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    var executable = repository.appendingPathComponent("target/debug/shipios-agent")
    if delayedAgentStartup {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let wrapper = root.appendingPathComponent("delayed-agent.sh")
      let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
      try "#!/bin/sh\n/bin/sleep 6\nexec \(quoted) \"$@\"\n".write(to: wrapper,
        atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
      executable = wrapper
    }
    let store = WorkspaceStore(dataRoot: root, agentExecutable: executable)
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
    // Launching Core is a prerequisite, not part of the fixture's stream delay.
    // Keep both phases bounded and retain the stricter stream readiness check.
    let startupDeadline = ContinuousClock.now.advanced(by: .seconds(15))
    var streamDeadline: ContinuousClock.Instant?
    while store.library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.isEmpty != false {
      let run = store.library.chatRuns.first(where: { $0.id == runID })
      let phases = (try? String(contentsOf: trace)) ?? "No model fixture requests"
      if streamDeadline == nil, phases.split(separator: "\n").contains(where: { line in
        guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return false }
        return event["phase"].text == "post" && event["path"].text == (api == .codexResponses
          ? "/v1/responses" : "/v1/chat/completions")
      }) { streamDeadline = ContinuousClock.now.advanced(by: .seconds(5)) }
      guard run?.status == "running", ContinuousClock.now < (streamDeadline ?? startupDeadline) else {
        let phase = streamDeadline == nil ? "Agent startup / request preparation" : "model stream"
        XCTFail("No actual streamed response during \(phase): \(run?.status ?? "missing") \(run?.result?.pretty ?? "")\n\(phases)")
        await store.shutdown()
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(store.library.chatRuns.first(where: { $0.id == runID })?.status, "running",
      "Archive verification must operate on a live stream, not an already completed response")
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
  @MainActor func testCoreArchiveAfterSlowAgentStartupStillStopsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .command, delayedAgentStartup: true)
  }
  @MainActor func testBasicChatTaskWindowArchiveStopsActualStream() async throws {
    try await checkArchive(.chatCompletions, surface: .taskWindow)
  }
  @MainActor func testCoreTaskWindowArchiveStopsActualStream() async throws {
    try await checkArchive(.codexResponses, surface: .taskWindow)
  }

}
