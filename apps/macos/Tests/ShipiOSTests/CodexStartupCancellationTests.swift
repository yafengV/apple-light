import XCTest
@testable import ShipiOS

final class CodexStartupCancellationTests: XCTestCase {
  private var server: Process!
  private var endpoint = ""
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("core-startup-\(UUID())")
  private var trace: URL { root.appendingPathComponent("requests.jsonl") }
  private var launches: URL { root.appendingPathComponent("launches.txt") }

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/model_server.py")
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", fixture.path]
    server.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
      "TMPDIR": NSTemporaryDirectory(), "FIXTURE_EVENT_LOG": trace.path]
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
    try? FileManager.default.removeItem(at: root)
  }

  private func delayedExecutable() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let wrapper = root.appendingPathComponent("agent.sh")
    // Record the actual process before a delay longer than the cancellation deadline.
    // exec retains that PID when the real Agent starts.
    try "#!/bin/sh\nprintf '%s\\n' \"$$\" >> \(quoted(launches.path))\n/bin/sleep 6\nexec \(quoted(repository.appendingPathComponent("target/debug/shipios-agent").path)) \"$@\"\n"
      .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    return wrapper
  }

  private var config: ModelConfiguration {
    var config = ModelConfiguration()
    config.apiProtocol = .codexResponses
    config.model = "gpt-5.4"
    config.baseURL = endpoint
    return config
  }

  @MainActor private func waitForLaunch() async throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while true {
      if let text = try? String(contentsOf: launches), let pid = text.split(separator: "\n").first.flatMap({ Int32($0) }) {
        return pid
      }
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Delayed Agent did not launch") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private var modelRequestCount: Int {
    ((try? String(contentsOf: trace)) ?? "").split(separator: "\n").filter {
      guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) else { return false }
      return event["phase"].text == "post" && event["path"].text == "/v1/responses"
    }.count
  }

  @MainActor func testStoppingDuringStartupEndsRunWithoutSendingAndAllowsRetry() async throws {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"),
      agentExecutable: try delayedExecutable())
    await store.restore()
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let started = await store.startChat("cancel before initialize")
    let runID = try XCTUnwrap(started, store.error ?? "No run")
    let owner = try XCTUnwrap(store.library.task(containing: runID)?.id)
    let request = try XCTUnwrap(store.modelTask(runID: runID))
    let pid = try await waitForLaunch()
    let queue = QueuedMessage(taskID: owner, text: "keep queued")
    store.library.queuedMessages.append(queue)
    store.draft = "keep draft"
    let began = ContinuousClock.now
    await store.cancel(taskID: owner)
    await request.value
    XCTAssertLessThan(began.duration(to: .now), .seconds(2), "Stopping must not wait for Agent initialization")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == runID }?.status, "cancelled")
    XCTAssertNil(store.modelTask(runID: runID))
    XCTAssertEqual(modelRequestCount, 0, "Cancelled startup must never send a model request")
    XCTAssertEqual(store.library.queuedMessages, [queue])
    XCTAssertEqual(store.draft, "keep draft")
    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while kill(pid, 0) == 0, ContinuousClock.now < cleanupDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "The cancelled Agent process must be released")
    // Clear the preserved queue explicitly so a successful retry cannot drain it.
    store.library.queuedMessages.removeAll()
    let retried = await store.startChat("retry after cancelled startup", taskID: owner)
    let retryID = try XCTUnwrap(retried, store.error ?? "No retry")
    await store.modelTask(runID: retryID)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == retryID }?.status, "succeeded")
    XCTAssertEqual(modelRequestCount, 1)
    await store.shutdown()
  }

  @MainActor private func turn(_ transport: CodexChatTransport, id: String,
    executable: URL) async throws -> AsyncThrowingStream<JSONValue, Error> {
    try await transport.startTurn(taskID: id, workspace: root, executable: executable,
      config: config, key: nil, initialText: id, continuationText: id, images: [],
      fileAppendix: nil, mcpServers: [], permissions: .approveForMe,
      responses: .init(), webSearchMode: .disabled)
  }

  @MainActor func testCancellingOneSharedStartupWaiterKeepsOtherTaskAndSingleAgent() async throws {
    let executable = try delayedExecutable()
    let transport = CodexChatTransport(dataRoot: root.appendingPathComponent("Data"))
    let first = Task { try await turn(transport, id: UUID().uuidString, executable: executable) }
    _ = try await waitForLaunch()
    let second = Task { try await turn(transport, id: UUID().uuidString, executable: executable) }
    // Both startTurn calls have entered prepareClient before cancellation.
    await Task.yield()
    let began = ContinuousClock.now
    first.cancel()
    do { _ = try await first.value; XCTFail("Cancelled task received a stream") }
    catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
    XCTAssertLessThan(began.duration(to: .now), .seconds(2), "Each startup waiter must cancel independently")
    let stream = try await second.value
    var completed = false
    for try await event in stream { if event["type"].text == "task_complete" { completed = true } }
    XCTAssertTrue(completed)
    XCTAssertEqual(modelRequestCount, 1, "Only the surviving task can submit a turn")
    XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 1)
    await transport.shutdown()
  }

  @MainActor func testShutdownDuringStartupReleasesWaiterAndProcessWithoutSubmission() async throws {
    let transport = CodexChatTransport(dataRoot: root.appendingPathComponent("Data"))
    let executable = try delayedExecutable()
    let request = Task { try await turn(transport, id: UUID().uuidString, executable: executable) }
    let pid = try await waitForLaunch()
    let began = ContinuousClock.now
    await transport.shutdown()
    do { _ = try await request.value; XCTFail("Shutdown task received a stream") }
    catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
    XCTAssertLessThan(began.duration(to: .now), .seconds(2), "Shutdown must not await initialization")
    XCTAssertNotEqual(kill(pid, 0), 0)
    XCTAssertEqual(modelRequestCount, 0)
  }

  @MainActor func testImmediateRetrySurvivesCleanupOfCancelledStartupInSameWorkspace() async throws {
    let transport = CodexChatTransport(dataRoot: root.appendingPathComponent("Data"))
    let executable = try delayedExecutable(), id = UUID().uuidString
    let first = Task { try await turn(transport, id: id, executable: executable) }
    let oldPID = try await waitForLaunch()
    first.cancel()
    do { _ = try await first.value; XCTFail("Cancelled task received a stream") }
    catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
    // Retry without awaiting old process cleanup. A stale startup completion
    // cannot remove or publish over the new startup for the same directory.
    let stream = try await turn(transport, id: id, executable: executable)
    var completed = false
    for try await event in stream { if event["type"].text == "task_complete" { completed = true } }
    XCTAssertTrue(completed)
    XCTAssertEqual(modelRequestCount, 1)
    XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 2)
    XCTAssertNotEqual(kill(oldPID, 0), 0)
    await transport.shutdown()
  }
}
