import XCTest
@testable import ShipiOS

final class MCPToolCallTests: XCTestCase {
  private var process: Process!
  private var baseURL = ""
  private var fixtureRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
  }
  override func setUpWithError() throws {
    process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", fixtureRoot.appendingPathComponent("model_server.py").path]
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture failed") }
    baseURL = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if process?.isRunning == true { process.terminate(); process.waitUntilExit() }
  }
  @MainActor private func store(_ root: URL, result: JSONValue? = nil) async throws -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.modelConfiguration.baseURL = baseURL
    store.modelConfiguration.model = "fixture"
    store.notificationPreferences = .init(timing: .never)
    var server = MCPServerConfiguration()
    server.name = "fixture"; server.command = "/usr/bin/python3"
    server.arguments = ["-u", fixtureRoot.appendingPathComponent("mcp_server.py").path, "stdio"]
    server.environment = [.init(key: "CALL_LOG", value: root.appendingPathComponent("calls.jsonl").path)]
    if let result {
      let file = root.appendingPathComponent("fixture-result.json")
      try result.pretty.write(to: file, atomically: true, encoding: .utf8)
      server.environment.append(.init(key: "RESULT_FILE", value: file.path))
    }
    XCTAssertTrue(store.saveMCPServer(server))
    store.connectMCPServer(server.id)
    await store.mcpConnectionTasks[server.id]?.value
    XCTAssertEqual(store.mcpConnectionStates[server.id]?.tools.count, 2)
    return store
  }
  @MainActor private func approval(_ store: WorkspaceStore) async throws -> UUID {
    for _ in 0..<500 {
      if let id = store.mcpPendingApprovals.keys.first { return id }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure(message: "No pending approval")
  }

  @MainActor func testApproveExecutesOnlyAfterDecisionAndFeedsResultBackIntoModelAndHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let id = try await approval(store)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    XCTAssertEqual(store.library.chatRuns.last?.toolExecutions.first?.status, .awaitingApproval)
    let server = try XCTUnwrap(store.mcpServers.first)
    let connection = try XCTUnwrap(store.mcpConnections[server.id])
    let token = store.mcpConnectionTokens[server.id]
    XCTAssertTrue(store.saveMCPServer(server))
    XCTAssertTrue(store.mcpConnections[server.id] === connection)
    XCTAssertEqual(store.mcpConnectionTokens[server.id], token)
    XCTAssertNotNil(store.mcpPendingApprovals[id], "Unchanged settings must not reject a waiting tool call")
    let owner = store.selectedTask?.id
    store.clearUnreadTasks()
    XCTAssertEqual(store.nextAttentionTask?.id, owner)
    XCTAssertEqual(store.activeMCPApproval(taskID: owner), id)
    XCTAssertFalse(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: owner,
      context: .init(editingText: true)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    XCTAssertTrue(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: owner, context: .init()))
    await running.value
    let run = try XCTUnwrap(store.library.chatRuns.last)
    XCTAssertEqual(run.status, "succeeded")
    XCTAssertEqual(run.toolExecutions.map(\.status), [.succeeded])
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"))
    XCTAssertEqual(calls.split(separator: "\n").count, 1)
    XCTAssertTrue(calls.contains("hello"))
    let body = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(run.result?["response"].text).utf8))
    let messages = body["messages"].items
    XCTAssertEqual(messages.last?["role"].text, "tool")
    XCTAssertEqual(messages.last?["tool_call_id"].text, "call-1")
    XCTAssertTrue(messages.last?["content"].text?.contains("TOOL_OK") == true)
    XCTAssertEqual(messages[messages.count - 2]["tool_calls"].items.first?["id"].text, "call-1")
    let loaded = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(loaded.chatRuns.last?.toolExecutions, run.toolExecutions)
    let history = loaded.chatContext(taskID: store.selectedTask?.id)
    XCTAssertEqual(history.map(\.role), ["user", "assistant", "tool", "assistant"])
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    await store.shutdown()
  }

  @MainActor func testDenyNeverExecutesToolAndTellsModelItWasDenied() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let id = try await approval(store)
    store.resolveMCPApproval(id, decision: .deny)
    await running.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    XCTAssertEqual(store.library.chatRuns.last?.toolExecutions.first?.status, .denied)
    XCTAssertTrue(store.library.chatRuns.last?.result?["response"].text?.contains("User denied") == true)
    await store.shutdown()
  }

  @MainActor func testRichToolResultSurvivesRealCallModelContinuationAndReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = try AttachmentFixture.png().base64EncodedString()
    let result: JSONValue = .object(["content": .array([
      .object(["type": .string("text"), "text": .string("Readable tool result")]),
      .object(["type": .string("image"), "data": .string(png), "mimeType": .string("image/png")]),
      .object(["type": .string("resource"), "resource": .object([
        "uri": .string("memory://report"), "mimeType": .string("text/plain"), "text": .string("Embedded report")])]),
    ]), "structuredContent": .object(["count": .number(3)])])
    let store = try await store(root, result: result)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let approval = try await approval(store)
    store.resolveMCPApproval(approval, decision: .allowOnce)
    await running.value
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    let run = try XCTUnwrap(saved.chatRuns.last)
    let output = try XCTUnwrap(run.toolExecutions.first?.output)
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)), result)
    let document = MCPResultDocument.parse(output)
    XCTAssertEqual(document.blocks.count, 3)
    XCTAssertEqual(document.blocks[0].content, .text("Readable tool result"))
    XCTAssertEqual(document.blocks[1].content, .image(base64: png, mime: "image/png"))
    XCTAssertEqual(document.blocks[2].content, .resource(uri: "memory://report", mime: "text/plain", text: "Embedded report", blob: nil))
    XCTAssertEqual(try MCPResultMedia.thumbnail(base64: png, mime: "image/png", size: 640).width, 2)
    XCTAssertEqual(run.toolExecutions.first?.status, .succeeded)
    XCTAssertEqual(saved.chatContext(taskID: saved.task(containing: run.id)?.id).first(where: { $0.role == "tool" })?.content, output)
    await store.shutdown()
  }

  @MainActor func testTextAndToolChronologyPersistsThroughApprovalDenialAndReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call-timeline"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let first = try await approval(store)
    let initial = try XCTUnwrap(store.library.chatRuns.last?.responseItems)
    XCTAssertEqual(initial.count, 2)
    XCTAssertEqual(initial.first?.text, "**准备 1**：查找 👩🏽‍💻 e\u{301}。")
    XCTAssertEqual(initial.last, .tool(first))
    store.resolveMCPApproval(first, decision: .allowOnce)
    let second = try await approval(store)
    let pending = try XCTUnwrap(store.library.chatRuns.last?.responseItems)
    XCTAssertEqual(pending.count, 4)
    XCTAssertEqual(Array(pending.prefix(2)), initial)
    XCTAssertEqual(pending[2].text, "\n\n**准备 2**：查找 👩🏽‍💻 e\u{301}。")
    XCTAssertEqual(pending.last, .tool(second))
    store.resolveMCPApproval(second, decision: .deny)
    await running.value
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let items = try XCTUnwrap(run.responseItems)
    XCTAssertEqual(items.count, 5)
    XCTAssertEqual(Array(items.prefix(4)), pending)
    XCTAssertEqual(items.last?.text, "\n\n## 最终回答\n\n查找已完成。")
    XCTAssertEqual(items.compactMap(\.text).joined(), run.result?["response"].text)
    XCTAssertEqual(run.toolExecutions.map(\.status), [.succeeded, .denied])
    let loaded = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(loaded.chatRuns.last?.responseItems, items)
    let matches = ConversationSearch.find(ConversationSearch.inputs([run], library: loaded), query: "查找")
    XCTAssertEqual(matches.count, 3)
    XCTAssertEqual(Set(matches.map(\.textID)).count, 3)
    await store.shutdown()
  }

  @MainActor func testTaskGrantAllowsSameToolAgainButDoesNotAuthorizeAnotherTask() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call-twice"
    await store.sendDraft()
    let first = try XCTUnwrap(store.modelTask)
    let id = try await approval(store)
    store.resolveMCPApproval(id, decision: .allowTask)
    await first.value
    XCTAssertEqual(store.library.chatRuns.last?.toolExecutions.map(\.status), [.succeeded, .succeeded])
    store.newTask()
    store.draft = "mcp-call"
    await store.sendDraft()
    let second = try XCTUnwrap(store.modelTask)
    let secondID = try await approval(store)
    XCTAssertNotEqual(id, secondID)
    store.resolveMCPApproval(secondID, decision: .deny)
    await second.value
    let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"))
    XCTAssertEqual(calls.split(separator: "\n").count, 2)
    await store.shutdown()
  }

  @MainActor func testGoalFinalizationKeepsEarlierTimelineItemsAndRemovesOnlyFinalStatusMarker() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    XCTAssertTrue(store.configureGoal(.init(objective: "timeline", successCriteria: ["done"])))
    store.draft = "mcp-call-timeline-goal"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let first = try await approval(store)
    store.resolveMCPApproval(first, decision: .allowTask)
    await running.value
    let run = try XCTUnwrap(store.library.chatRuns.last)
    let items = try XCTUnwrap(run.responseItems)
    XCTAssertEqual(items.count, 5)
    XCTAssertEqual(items[0].text, "**准备 1**：查找 👩🏽‍💻 e\u{301}。")
    XCTAssertEqual(items[2].text, "\n\n**准备 2**：查找 👩🏽‍💻 e\u{301}。")
    XCTAssertEqual(items[4].text, "## 最终回答\n\n查找已完成。")
    XCTAssertFalse(items.compactMap(\.text).joined().contains("SHIPIOS_GOAL_STATUS"))
    XCTAssertEqual(store.goalSession(for: store.selectedTask?.id)?.status, .completed)
    await store.shutdown()
  }

  @MainActor func testCancelDuringApprovalClearsContinuationAndPreservesBalancedHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    _ = try await approval(store)
    running.cancel()
    await running.value
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    XCTAssertTrue(store.mcpApprovalContinuations.isEmpty)
    XCTAssertEqual(store.library.chatRuns.last?.status, "cancelled")
    XCTAssertEqual(store.library.chatRuns.last?.toolExecutions.first?.status, .cancelled)
    XCTAssertEqual(store.library.chatContext(taskID: store.selectedTask?.id).map(\.role), ["user", "assistant", "tool"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    await store.shutdown()
  }

  @MainActor func testDisconnectDuringApprovalCannotUseStaleConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let id = try await approval(store)
    let serverID = try XCTUnwrap(store.mcpPendingApprovals[id]?.execution.serverID)
    store.disconnectMCPServer(serverID)
    store.resolveMCPApproval(id, decision: .allowOnce)
    await running.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    await store.shutdown()
  }

  func testToolStreamRejectsIncompleteOrInvalidArguments() throws {
    var accumulator = ModelToolCallAccumulator()
    try accumulator.append([.object(["index": .number(0), "id": .string("one"), "type": .string("function"),
      "function": .object(["name": .string("tool"), "arguments": .string("{\"x\":")])])])
    XCTAssertThrowsError(try accumulator.completed(reason: "stop"))
    XCTAssertThrowsError(try accumulator.completed(reason: "tool_calls"))
    try accumulator.append([.object(["index": .number(0), "function": .object(["arguments": .string("1}")])])])
    XCTAssertEqual(try accumulator.completed(reason: "tool_calls").first?.arguments, "{\"x\":1}")
  }

  @MainActor func testStoppingAnswerAfterToolExecutionRetainsPartialAnswerInHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call-slow"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    let id = try await approval(store)
    store.resolveMCPApproval(id, decision: .allowOnce)
    for _ in 0..<500 {
      if store.library.chatRuns.last?.result?["response"].text?.contains("partial-final") == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    running.cancel()
    await running.value
    XCTAssertEqual(store.library.chatRuns.last?.status, "cancelled")
    XCTAssertTrue(store.library.chatContext(taskID: store.selectedTask?.id).last?.content.contains("partial-final") == true)
    XCTAssertEqual(store.library.chatRuns.last?.toolExecutions.first?.status, .succeeded)
    let items = try XCTUnwrap(store.library.chatRuns.last?.responseItems)
    XCTAssertEqual(items[1], .tool(id))
    XCTAssertTrue(items.last?.text?.contains("partial-final") == true)
    let loaded = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(loaded.chatRuns.last?.responseItems, items)
    await store.shutdown()
  }

  @MainActor func testRestoreMarksPendingToolAsCancelledWithoutReplayingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await store(root)
    store.draft = "mcp-call"
    await store.sendDraft()
    let running = try XCTUnwrap(store.modelTask)
    _ = try await approval(store)
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    running.cancel()
    await running.value
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("Restored"))
    restored.library = saved
    restored.libraryLoaded = true
    restored.restoreInterruptedChats()
    XCTAssertEqual(restored.library.chatRuns.last?.responseItems, saved.chatRuns.last?.responseItems)
    XCTAssertEqual(restored.library.chatRuns.last?.status, "interrupted")
    XCTAssertEqual(restored.library.chatRuns.last?.toolExecutions.first?.status, .cancelled)
    XCTAssertTrue(restored.mcpPendingApprovals.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path))
    await store.shutdown()
  }
}
