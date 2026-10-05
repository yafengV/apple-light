import XCTest
import SwiftUI
@testable import ShipiOS

final class SubagentElicitationTests: XCTestCase {
  private func event(token: String = UUID().uuidString, url: Bool = false) -> JSONValue {
    .object(["type": .string("elicitation_request"), "turn_id": .null, "server_name": .string("fixture"), "id": .string("request"),
      "shipios_elicitation": .object(["token": .string(token), "turnId": .string("child-turn"),
        "choices": .array((url ? ["accept", "cancel"] : ["accept", "decline", "cancel"]).map(JSONValue.string))]),
      "request": url ? .object(["mode": .string("url"), "message": .string("Verify"), "elicitation_id": .string("url-id"),
        "url": .string("https://example.com/verify?one_time=volatile-secret")]) : .object([
        "mode": .string("form"), "message": .string("Typed answer"), "requested_schema": .object([
          "type": .string("object"), "properties": .object(["count": .object(["type": .string("integer"), "minimum": .number(1)])]),
          "required": .array([.string("count")])])])])
  }
  func testNativeNullTurnAndTypedFormURLValidationRemainSeparate() throws {
    let raw = event(), form = try XCTUnwrap(SubagentElicitationRequest(raw))
    XCTAssertEqual(raw["turn_id"], .null); XCTAssertEqual(form.turnID, "child-turn")
    XCTAssertEqual(form.request.id.uuidString.lowercased(), form.id.lowercased())
    XCTAssertFalse(form.allows(.accept, content: .object(["count": .string("2")])))
    XCTAssertFalse(form.allows(.accept, content: .object(["count": .number(0)])))
    XCTAssertFalse(form.allows(.acceptForSession, content: nil))
    XCTAssertTrue(form.allows(.accept, content: .object(["count": .number(2)])))
    XCTAssertTrue(form.allows(.decline, content: nil))
    let url = try XCTUnwrap(SubagentElicitationRequest(event(url: true)))
    XCTAssertEqual(url.request.urlDisplay, "example.com")
    XCTAssertTrue(url.verificationURL?.absoluteString.contains("volatile-secret") == true)
    XCTAssertFalse(url.request.schema.pretty.contains("volatile-secret"))
    XCTAssertFalse(url.allows(.accept, content: .object([:])))
    XCTAssertTrue(url.allows(.cancel, content: nil))
  }
  func testWrongChildStaleRevisionChangedTurnAndTerminalReactivationAreRejected() {
    let token = UUID().uuidString
    func state(_ revision: Int, _ phase: String, child: String = "child", turn: String = "turn") -> JSONValue {
      .object(["type": .string("shipios_subagent_elicitation_state"), "childThreadId": .string(child),
        "turnId": .string(turn), "requestToken": .string(token), "revision": .number(Double(revision)), "state": .string(phase), "choice": .string("cancel")])
    }
    var live = SubagentLiveState()
    live.receiveElicitation(state(1, "pending", child: "peer"), child: "child"); XCTAssertTrue(live.elicitations.isEmpty)
    live.receiveElicitation(state(1, "pending"), child: "child")
    live.receiveElicitation(state(4, "resolved", turn: "wrong"), child: "child")
    XCTAssertEqual(live.elicitations[token]?.phase, .pending)
    live.receiveElicitation(state(3, "resolved"), child: "child")
    live.receiveElicitation(state(2, "pending"), child: "child")
    live.receiveElicitation(state(4, "pending"), child: "child")
    XCTAssertEqual(live.elicitations[token]?.phase, .resolved)
    XCTAssertEqual(live.elicitations[token]?.choice, .cancel)
  }
  func testCapturedUnsafeURLCanBeCancelledWithoutOpeningOrSubmittingIt() throws {
    var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event(url: true))) as? [String: Any])
    var request = try XCTUnwrap(raw["request"] as? [String: Any]); request["url"] = "file:///private/unsafe"
    raw["request"] = request
    let parsed = try XCTUnwrap(SubagentElicitationRequest(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: raw))))
    XCTAssertNotNil(parsed.issue); XCTAssertNil(parsed.verificationURL)
    XCTAssertFalse(parsed.allows(.accept, content: nil)); XCTAssertTrue(parsed.allows(.cancel, content: nil))
  }
  @MainActor func testInlineRequestCardsAndTranscriptRenderFormAndURLAtBothWidths() throws {
    for url in [false, true] {
      let request = try XCTUnwrap(SubagentElicitationRequest(event(url: url)))
      let transcript = SubagentTranscript(events: [event(token: request.id, url: url)])
      XCTAssertEqual(transcript.entries.first?.kind, .elicitation)
      XCTAssertEqual(transcript.entries.first?.elicitation?.id, request.id)
      for width in [300.0, 760.0] {
        let host = NSHostingView(rootView: SubagentElicitationCard(request: request,
          status: .init(turnID: request.turnID, revision: 1, phase: .pending, choice: nil),
          busy: false, error: "Retry", openURL: { _ in }, submit: { _, _ in }))
        host.frame = .init(x: 0, y: 0, width: width, height: 500); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
      }
    }
  }
}

final class SubagentElicitationIntegrationTests: XCTestCase {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-mcp-\(UUID())")
  var server: Process!
  var endpoint = ""
  private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures") }
  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [fixtures.appendingPathComponent("subagent_mcp_model_server.py").path]
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run(); var data = Data()
    while !data.contains(10) { data.append(output.fileHandleForReading.readData(ofLength: 1)) }
    endpoint = "http://127.0.0.1:\(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }
  @MainActor func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition() { guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Child MCP timed out") }; try await Task.sleep(for: .milliseconds(20)) }
  }
  @MainActor func setup(mode: String, delivery: (any NotificationDelivery)? = nil) async throws -> (WorkspaceStore, String, String, CodexSubagent, SubagentElicitationRequest, URL) {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses; config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    if let delivery { store.notifications = CompletionNotificationCenter(delivery: delivery) }
    addTeardownBlock { await store.shutdown() }
    let log = root.appendingPathComponent("mcp-answer.jsonl")
    var mcp = MCPServerConfiguration(); mcp.name = "shipios_capture"; mcp.command = "/usr/bin/python3"
    mcp.arguments = mode == "url" ? [fixtures.appendingPathComponent("subagent_mcp_server.py").path]
      : [fixtures.appendingPathComponent("mcp_server.py").path, mode == "tool" ? "stdio" : "stdio_form"]
    mcp.environment = [.init(key: "CALL_LOG", value: log.path), .init(key: "SHIPIOS_CODEX_PROBE", value: mode == "tool" ? "" : "1")]
    XCTAssertTrue(store.saveMCPServer(mcp), store.mcpServersError ?? "")
    let started = await store.startChat("parent-mcp")
    let run = try XCTUnwrap(started), task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false && !store.subagents(taskID: task).isEmpty }
    let child = try XCTUnwrap(store.subagents(taskID: task).first)
    do { try await waitFor { store.subagentLiveStates[child.id]?.events.contains { SubagentElicitationRequest($0) != nil } == true } }
    catch { print("CHILD MCP DIAGNOSTIC", store.subagentLiveStates[child.id]?.events.suffix(12) ?? [], store.error ?? ""); throw error }
    let request = try XCTUnwrap(store.subagentLiveStates[child.id]?.events.compactMap(SubagentElicitationRequest.init).first)
    return (store, task, run, child, request, log)
  }
  @MainActor func testActualChildTypedFormRejectsForeignIdentityAndReusedTokenThenCompletes() async throws {
    let (store, task, run, child, request, log) = try await setup(mode: "form")
    let answer = JSONValue.object(["count": .number(2), "reason": .string("fixture child reason")])
    let raw = try XCTUnwrap(store.subagentLiveStates[child.id]?.events.first { SubagentElicitationRequest($0)?.id == request.id })
    XCTAssertEqual(raw["turn_id"], .null)
    do { try await store.codexTransport.resolveSubagentElicitation(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.rootThreadID, request: request, choice: .accept, content: answer); XCTFail("Root accepted as child") } catch {}
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .accept, content: .object(["count": .string("2")]))
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[request.id]?.phase, .pending)
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .accept, content: answer)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[request.id]?.phase, .resolved)
    let results = try String(contentsOf: log, encoding: .utf8)
    XCTAssertTrue(results.contains("fixture child reason")); XCTAssertTrue(results.contains("\"count\": 2"))
    do { try await store.codexTransport.resolveSubagentElicitation(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, request: request, choice: .accept, content: answer); XCTFail("Reused token accepted") } catch {}
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
    let saved = String(decoding: try Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains(request.id)); XCTAssertFalse(saved.contains("fixture child reason"))
  }
  @MainActor func testActualChildURLStopExpiresOldReplyAndCancelTargetsOnlyNewRequest() async throws {
    let (store, task, run, child, old, log) = try await setup(mode: "url")
    XCTAssertEqual(old.request.urlDisplay, "example.com"); XCTAssertTrue(old.verificationURL?.absoluteString.contains("fixture-secret") == true)
    await store.stopSubagent(taskID: task, agent: child, expectedTurnID: old.turnID)
    try await waitFor { store.subagentLiveStates[child.id]?.elicitations[old.id]?.phase == .expired && store.subagents(taskID: task).first { $0.id == child.id }?.status == .interrupted }
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "fixture-child-mcp again", expectedTurnID: nil)
    try await waitFor { store.subagentLiveStates[child.id]?.events.compactMap(SubagentElicitationRequest.init).contains { $0.id != old.id } == true }
    let next = try XCTUnwrap(store.subagentLiveStates[child.id]?.events.compactMap(SubagentElicitationRequest.init).last)
    XCTAssertNotEqual(next.turnID, old.turnID)
    do { try await store.codexTransport.resolveSubagentElicitation(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, request: old, choice: .accept, content: nil); XCTFail("Old URL accepted") } catch {}
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[next.id]?.phase, .pending)
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: next, choice: .cancel, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines.first?.contains("cancel") == true)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
    let saved = String(decoding: try Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains("fixture-secret")); XCTAssertFalse(saved.contains(next.id))
    await store.shutdown(); XCTAssertNil(store.subagentLiveStates[child.id]); XCTAssertTrue(store.subagentElicitationBusy.isEmpty)
  }
  @MainActor func testActualChildToolSessionApprovalRunsToolAndPersistsOnlyNativePolicy() async throws {
    let (store, task, run, child, request, log) = try await setup(mode: "tool")
    XCTAssertTrue(request.isTool); XCTAssertTrue(request.choices.contains(.acceptForSession))
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .acceptForSession, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "fixture-child-mcp again", expectedTurnID: nil)
    try await waitFor { store.subagentLiveStates[child.id]?.events.filter { $0["type"].text == "task_complete" }.count == 2 }
    XCTAssertEqual(store.subagentLiveStates[child.id]?.events.compactMap(SubagentElicitationRequest.init).count, 1)
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 2)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
  }
  @MainActor func testActualChildFormRefusalReturnsDeclineWithoutAnAnswerAndKeepsParent() async throws {
    let (store, task, run, child, request, log) = try await setup(mode: "form")
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .decline, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    let answer = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(lines.first).utf8))
    XCTAssertEqual(answer["action"].text, "decline"); XCTAssertEqual(answer["content"], .null)
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[request.id]?.choice, .decline)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
  }
  @MainActor func testActualChildToolDenialDoesNotExecuteAndKeepsParent() async throws {
    let (store, task, run, child, request, log) = try await setup(mode: "tool")
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .decline, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[request.id]?.choice, .decline)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
  }
}
