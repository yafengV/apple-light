import XCTest
@testable import ShipiOS

final class GitGenerationFixture {
  let process = Process()
  let log: URL
  let phaseLog: URL
  var config = ModelConfiguration()
  init(root: URL) throws {
    let git = root.appendingPathComponent(".git")
    log = (FileManager.default.fileExists(atPath: git.path) ? git : root).appendingPathComponent("generation-requests.jsonl")
    phaseLog = log.appendingPathExtension("phases")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/git_generation_server.py")
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", script.path]
    process.environment = ["GENERATION_REQUEST_LOG": log.path, "GENERATION_PHASE_LOG": phaseLog.path]
    let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Generation fixture failed") }
    config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "gpt-5.4"
    config.apiProtocol = .codexResponses; config.reasoning = "low"
  }
  func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
  func records() throws -> [JSONValue] {
    guard FileManager.default.fileExists(atPath: log.path) else { return [] }
    return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
      .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
  }
  func waitForRequest(count: Int = 1) async throws {
    for _ in 0..<3000 {
      if try records().count >= count { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure(message: "Generation request was not received")
  }
  func waitForPhase(_ phase: String) async throws {
    for _ in 0..<3000 {
      if let phases = try? String(contentsOf: phaseLog, encoding: .utf8),
        phases.split(separator: "\n").contains(Substring(phase)) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure(message: "Generation phase was not received")
  }
}

final class GitResponsesGenerationTests: XCTestCase {
  private var root: URL!
  private var fixture: GitGenerationFixture!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("git-responses-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    fixture = try GitGenerationFixture(root: root)
  }
  override func tearDown() {
    fixture?.stop(); try? FileManager.default.removeItem(at: root)
  }
  private var dataRoot: URL { root.appendingPathComponent("private-generation-data") }
  @MainActor private func generate(_ instruction: String, content: String = "Captured Git diff") async throws -> String {
    try await GitTextGenerator.make(config: fixture.config, key: nil, repository: root,
      dataRoot: dataRoot, executable: try AgentTestExecutable.url())([
        ChatMessage(role: "system", content: instruction), ChatMessage(role: "user", content: content)])
  }
  private func assertCleaned(file: StaticString = #filePath, line: UInt = #line) throws {
    let parent = dataRoot.appendingPathComponent("GitGenerations")
    let entries = FileManager.default.fileExists(atPath: parent.path)
      ? try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) : []
    XCTAssertTrue(entries.isEmpty, "Temporary Core histories and auth must be removed", file: file, line: line)
  }

  @MainActor func testResponsesRoutePreservesLargeContextAndExcludesToolsAndRepositoryInstructions() async throws {
    try "repository-instructions-must-not-enter-generation".write(to: root.appendingPathComponent("AGENTS.md"),
      atomically: true, encoding: .utf8)
    let content = String(repeating: "Captured diff 世界\n", count: 3500)
    XCTAssertGreaterThan(content.utf8.count, 48_000)
    let output = try await generate("fixture-echo-generation", content: content)
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(output.utf8))
    XCTAssertEqual(messages.last?.content, content)
    let requests = try fixture.records()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?["path"].text, "/v1/responses")
    XCTAssertEqual(requests.first?["body"]["model"].text, "gpt-5.4")
    XCTAssertEqual(requests.first?["body"]["reasoning"]["effort"].text, "low")
    XCTAssertTrue(requests.allSatisfy { $0["body"]["tools"].items.isEmpty })
    let body = String(decoding: try JSONEncoder().encode(requests[0]["body"]), as: UTF8.self)
    XCTAssertFalse(body.contains("repository-instructions-must-not-enter-generation"))
    XCTAssertFalse(body.contains("apply_patch"))
    try assertCleaned()
  }

  @MainActor func testCancellationKeepsCallerDraftAndRemovesEphemeralHistory() async throws {
    let operation = Task { try await generate("fixture-slow-generation") }
    try await fixture.waitForRequest()
    operation.cancel()
    do { _ = try await operation.value; XCTFail("Cancelled generation must not return text") }
    catch { XCTAssertTrue(error is CancellationError) }
    try assertCleaned()
  }

  @MainActor func testErrorAndEmptyResponseDoNotReturnSuccessfulText() async throws {
    for instruction in ["fixture-generation-error", "fixture-empty-generation"] {
      do { _ = try await generate(instruction); XCTFail("Invalid response must fail") }
      catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      try assertCleaned()
    }
    XCTAssertTrue(try fixture.records().allSatisfy { $0["path"].text == "/v1/responses" })
  }

  @MainActor func testTimeoutDuringResponseRemovesTemporarySessionAndReportsFailure() async throws {
    let operation = Task {
      try await CodexTextGeneration.generate(config: fixture.config, key: nil,
        messages: [ChatMessage(role: "system", content: "fixture-slow-generation")],
        repository: root, dataRoot: dataRoot, executable: try AgentTestExecutable.url(), timeout: .seconds(3))
    }
    try await fixture.waitForRequest()
    do { _ = try await operation.value; XCTFail("Timed out generation must not return text") }
    catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    try assertCleaned()
  }

  @MainActor func testUnadvertisedToolAttemptCannotExecuteInRepository() async throws {
    do { _ = try await generate("fixture-tool-generation") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("generation-tool-must-not-run.txt").path))
    let requests = try fixture.records()
    XCTAssertFalse(requests.isEmpty)
    XCTAssertTrue(requests.allSatisfy { $0["body"]["tools"].items.isEmpty })
    try assertCleaned()
  }

  @MainActor func testTemporaryGenerationDoesNotChangeOrStopExistingCodingThread() async throws {
    let transport = CodexChatTransport(dataRoot: root.appendingPathComponent("coding-data"))
    let taskID = UUID().uuidString
    do {
      for round in 0..<2 {
        let stream = try await transport.startTurn(taskID: taskID, workspace: root,
          executable: try AgentTestExecutable.url(), config: fixture.config, key: nil,
          initialText: "normal-chat-proof", continuationText: "normal-chat-proof continued",
          images: [], fileAppendix: nil, mcpServers: [], permissions: AgentRuntimePreferences(),
          responses: AgentResponsePreferences(), webSearchMode: .disabled)
        var completed = false
        for try await event in stream { if event["type"].text == "task_complete" { completed = true } }
        XCTAssertTrue(completed)
        if round == 0 {
          let output = try await generate("Generate a concise commit message")
          XCTAssertEqual(output, "Responses commit 世界")
        }
      }
      let requests = try fixture.records()
      XCTAssertEqual(requests.count, 3)
      XCTAssertFalse(requests[0]["body"]["tools"].items.isEmpty)
      XCTAssertTrue(requests[1]["body"]["tools"].items.isEmpty)
      XCTAssertFalse(requests[2]["body"]["tools"].items.isEmpty)
      try assertCleaned()
      await transport.shutdown()
    } catch { await transport.shutdown(); throw error }
  }
}
