import XCTest
import SwiftUI
@testable import ShipiOS

final class SubagentApprovalTests: XCTestCase {
  private func request(token: String = UUID().uuidString, patch: Bool = false) throws -> SubagentApprovalRequest {
    try XCTUnwrap(SubagentApprovalRequest(.object([
      "type": .string(patch ? "apply_patch_approval_request" : "exec_approval_request"),
      "turn_id": .string("turn"), "command": .array([.string("printf"), .string("proof")]),
      "shipios_approval": .object(["token": .string(token), "decisions": .array([.string("approved"), .string("abort")])]) ])))
  }
  func testApprovalStatusRejectsWrongChildOldRevisionChangedTurnAndReactivation() throws {
    let token = UUID().uuidString
    func packet(_ revision: Int, _ state: String, child: String = "child", turn: String = "turn") -> JSONValue {
      .object(["type": .string("shipios_subagent_approval_state"), "childThreadId": .string(child),
        "requestToken": .string(token), "turnId": .string(turn), "revision": .number(Double(revision)), "state": .string(state)])
    }
    var live = SubagentLiveState()
    live.receiveApproval(packet(1, "pending", child: "peer"), child: "child"); XCTAssertTrue(live.approvals.isEmpty)
    live.receiveApproval(packet(1, "pending"), child: "child")
    live.receiveApproval(packet(3, "resolved", turn: "wrong"), child: "child")
    XCTAssertEqual(live.approvals[token]?.phase, .pending)
    live.receiveApproval(packet(3, "resolved"), child: "child")
    live.receiveApproval(packet(2, "pending"), child: "child")
    live.receiveApproval(packet(4, "pending"), child: "child")
    XCTAssertEqual(live.approvals[token]?.phase, .resolved)
  }
  @MainActor func testInlineCardUsesOriginalTokenAndNativeChoicesAtNarrowAndWideWidths() throws {
    for patch in [false, true] {
      let request = try request(patch: patch)
      let transcript = SubagentTranscript(events: [request.event])
      XCTAssertEqual(transcript.entries.first?.kind, .approval)
      XCTAssertEqual(transcript.entries.first?.approval?.id, request.id)
      XCTAssertEqual(request.decisions.map(SubagentApprovalRequest.title), ["允许一次", "拒绝并停止"])
      for width in [300.0, 760.0] {
        let host = NSHostingView(rootView: SubagentApprovalCard(request: request,
          status: .init(turnID: request.turnID, revision: 1, phase: .pending), busy: false, error: "Retry", choose: { _ in }))
        host.frame = .init(x: 0, y: 0, width: width, height: 400); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
      }
    }
  }
}

final class SubagentApprovalIntegrationTests: XCTestCase {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-approval-\(UUID())")
  var server: Process!
  var endpoint = ""
  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/subagent_approval_server.py").path]
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    var data = Data()
    while !data.contains(10) { data.append(output.fileHandleForReading.readData(ofLength: 1)) }
    let port = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }
  @MainActor private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Child approval timed out") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  @MainActor func setup(patch: Bool = false) async throws -> (WorkspaceStore, String, String, CodexSubagent, SubagentApprovalRequest) {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses; config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    addTeardownBlock { await store.shutdown() }
    if patch { store.library.agentRuntimePreferences.sandboxMode = .readOnly }
    let started = await store.startChat(patch ? "parent-patch" : "parent-approval")
    let run = try XCTUnwrap(started)
    let task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false && !store.subagents(taskID: task).isEmpty }
    let child = try XCTUnwrap(store.subagents(taskID: task).first)
    do {
      try await waitFor { store.subagentLiveStates[child.id]?.events.contains { SubagentApprovalRequest($0) != nil } == true }
    } catch {
      print("APPROVAL DIAGNOSTIC", store.subagents(taskID: task), store.subagentLiveStates[child.id]?.events.suffix(12) ?? [], store.error ?? "")
      throw error
    }
    let request = try XCTUnwrap(store.subagentLiveStates[child.id]?.events.compactMap(SubagentApprovalRequest.init).first)
    return (store, task, run, child, request)
  }
  @MainActor func testActualChildApprovalRejectsWrongIdentityThenExecutesOnceAndKeepsParentReply() async throws {
    let (store, task, run, child, request) = try await setup()
    do {
      try await store.codexTransport.resolveSubagentApproval(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.rootThreadID, request: request, choice: 0)
      XCTFail("Root was accepted as child")
    } catch {}
    let path = try XCTUnwrap(store.library.tasks.first { $0.id == task }?.codexWorkspacePath)
    let marker = URL(fileURLWithPath: path).appendingPathComponent("child-approval-proof.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let choice = try XCTUnwrap(request.decisions.firstIndex(of: .string("approved")))
    await store.resolveSubagentApproval(taskID: task, agent: child, request: request, choice: choice)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "approved")
    XCTAssertEqual(store.subagentLiveStates[child.id]?.approvals[request.id]?.phase, .resolved)
    do {
      try await store.codexTransport.resolveSubagentApproval(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.threadID, request: request, choice: choice)
      XCTFail("Token was reused")
    } catch {}
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent is complete")
  }
  @MainActor func testActualChildRefusalStopsChildWithoutExecutingOrChangingParent() async throws {
    let (store, task, run, child, request) = try await setup()
    let abort = try XCTUnwrap(request.decisions.firstIndex(of: .string("abort")))
    await store.resolveSubagentApproval(taskID: task, agent: child, request: request, choice: abort)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .interrupted }
    let directory = URL(fileURLWithPath: try XCTUnwrap(store.library.tasks.first { $0.id == task }?.codexWorkspacePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-approval-proof.txt").path))
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "succeeded")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent is complete")
  }
  @MainActor func testExpiredTokenAndInvalidChoiceCannotResolveAReplacementRequest() async throws {
    let (store, task, run, child, old) = try await setup()
    do {
      try await store.codexTransport.resolveSubagentApproval(taskID: task, rootThreadID: UUID().uuidString,
        childThreadID: child.threadID, request: old, choice: 0)
      XCTFail("Changed root identity was accepted")
    } catch {}
    var event = old.event
    if case .object(var fields) = event, case .object(var metadata) = fields["shipios_approval"] {
      metadata["decisions"] = .array(old.decisions + [.string("approved")])
      fields["shipios_approval"] = .object(metadata); event = .object(fields)
    }
    let forged = try XCTUnwrap(SubagentApprovalRequest(event))
    do {
      try await store.codexTransport.resolveSubagentApproval(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.threadID, request: forged, choice: old.decisions.count)
      XCTFail("A fabricated native choice was accepted")
    } catch {}
    XCTAssertEqual(store.subagentLiveStates[child.id]?.approvals[old.id]?.phase, .pending)
    await store.cancel(taskID: task)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .interrupted &&
      store.subagentLiveStates[child.id]?.approvals[old.id]?.phase == .expired }
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "fixture-native-child-request again", expectedTurnID: nil)
    try await waitFor { store.subagentLiveStates[child.id]?.events.compactMap(SubagentApprovalRequest.init).contains { $0.id != old.id } == true }
    let next = try XCTUnwrap(store.subagentLiveStates[child.id]?.events.compactMap(SubagentApprovalRequest.init).last)
    XCTAssertNotEqual(next.id, old.id); XCTAssertNotEqual(next.turnID, old.turnID)
    do {
      try await store.codexTransport.resolveSubagentApproval(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.threadID, request: old, choice: 0)
      XCTFail("An expired token resolved the replacement request")
    } catch {}
    XCTAssertEqual(store.subagentLiveStates[child.id]?.approvals[next.id]?.phase, .pending)
    await store.resolveSubagentApproval(taskID: task, agent: child, request: next, choice: 0)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent is complete")
    let saved = String(decoding: try Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains(next.id)); XCTAssertFalse(saved.contains(old.id))
    await store.shutdown(); XCTAssertNil(store.subagentLiveStates[child.id])
  }

  @MainActor func testActualReadOnlyChildPatchApprovalForSessionWritesOnlyAfterAction() async throws {
    let (store, task, run, child, request) = try await setup(patch: true)
    XCTAssertEqual(request.event["type"].text, "apply_patch_approval_request")
    let directory = URL(fileURLWithPath: try XCTUnwrap(store.library.tasks.first { $0.id == task }?.codexWorkspacePath))
    let marker = directory.appendingPathComponent("child-patch-proof.txt")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    let choice = try XCTUnwrap(request.decisions.firstIndex(of: .string("approved_for_session")))
    await store.resolveSubagentApproval(taskID: task, agent: child, request: request, choice: choice)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "patched\n")
    XCTAssertEqual(store.subagentLiveStates[child.id]?.approvals[request.id]?.phase, .resolved)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent is complete")
  }

}
