import XCTest
@testable import ShipiOS

extension SubagentElicitationIntegrationTests {
  @MainActor func testActualChildFormProjectsAttentionAfterParentEndsAndNotificationRevealsOnlyItsRequest() async throws {
    let delivery = ChildRequestNotificationDelivery()
    let (store, task, run, child, request, log) = try await setup(mode: "form", delivery: delivery)
    try await waitFor { store.subagentElicitations(taskID: task).count == 1 && delivery.notices.contains { $0.kind == .question } }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.status, "succeeded")
    let row = try XCTUnwrap(store.subagentElicitations(taskID: task).first)
    XCTAssertEqual(row.agent.id, child.id); XCTAssertEqual(row.request.id, request.id)
    XCTAssertEqual(store.taskAttentionKind(for: try XCTUnwrap(store.library.tasks.first { $0.id == task })), .elicitation)
    store.toggleActivity()
    XCTAssertTrue(store.activityPriorityEntries.contains { $0.id == task && $0.running && $0.attention == .elicitation })
    store.notifySubagentRequests(taskID: task); store.notifySubagentRequests(taskID: task)
    await Task.yield()
    XCTAssertEqual(delivery.notices.filter { $0.kind == .question }.count, 1)
    let target = try XCTUnwrap(delivery.notices.first { $0.kind == .question }?.destination)
    XCTAssertEqual(target.subagent, .init(rootThreadID: child.rootThreadID, childThreadID: child.threadID, requestToken: request.id))
    XCTAssertEqual(NotificationDestination(userInfo: target.userInfo), target)
    let opened = await store.openNotification(target); XCTAssertTrue(opened)
    XCTAssertEqual(store.selectedTask?.id, task); XCTAssertEqual(store.conversationReveal?.childRequestID, row.id)
    let peer = NotificationDestination(dataRoot: store.dataRoot.path, project: "", taskID: task, runID: run,
      subagent: .init(rootThreadID: child.rootThreadID, childThreadID: UUID().uuidString, requestToken: request.id))
    let openedPeer = await store.openNotification(peer); XCTAssertTrue(openedPeer)
    XCTAssertNil(store.conversationReveal?.childRequestID)
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .accept,
      content: .object(["count": .number(2), "reason": .string("projected answer")]))
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    XCTAssertNil(store.taskAttentionKind(for: try XCTUnwrap(store.library.tasks.first { $0.id == task })))
    XCTAssertFalse(store.activityEntries.first { $0.id == task }?.running ?? true)
    XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("projected answer"))
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
    let openedResolved = await store.openNotification(target); XCTAssertTrue(openedResolved)
    XCTAssertNil(store.conversationReveal?.childRequestID)
    let saved = String(decoding: try Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")), as: UTF8.self)
    XCTAssertFalse(saved.contains(request.id)); XCTAssertFalse(saved.contains("projected answer"))
  }

  @MainActor func testActualOldChildURLNotificationCannotRevealReplacementAndDisconnectClearsAttention() async throws {
    let delivery = ChildRequestNotificationDelivery()
    let (store, task, run, child, old, log) = try await setup(mode: "url", delivery: delivery)
    try await waitFor { delivery.notices.contains { $0.destination?.subagent?.requestToken == old.id } }
    let oldTarget = try XCTUnwrap(delivery.notices.first { $0.destination?.subagent?.requestToken == old.id }?.destination)
    await store.stopSubagent(taskID: task, agent: child, expectedTurnID: old.turnID)
    try await waitFor { store.subagentLiveStates[child.id]?.elicitations[old.id]?.phase == .expired
      && store.subagents(taskID: task).first { $0.id == child.id }?.status == .interrupted }
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "fixture-child-mcp again", expectedTurnID: nil)
    try await waitFor { store.subagentElicitations(taskID: task).contains { $0.request.id != old.id }
      && delivery.notices.contains { $0.destination?.subagent?.requestToken != old.id && $0.kind == .question } }
    let replacement = try XCTUnwrap(store.subagentElicitations(taskID: task).first)
    let newTarget = try XCTUnwrap(delivery.notices.first { $0.destination?.subagent?.requestToken == replacement.request.id }?.destination)
    let openedOld = await store.openNotification(oldTarget); XCTAssertTrue(openedOld)
    XCTAssertNil(store.conversationReveal?.childRequestID)
    XCTAssertEqual(store.subagentLiveStates[child.id]?.elicitations[replacement.request.id]?.phase, .pending)
    let openedNew = await store.openNotification(newTarget); XCTAssertTrue(openedNew)
    XCTAssertEqual(store.conversationReveal?.childRequestID, replacement.id)
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: replacement.request, choice: .cancel, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count, 1)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
    XCTAssertTrue(store.subagentNotifiedRequests.contains(child.id + ":" + old.id))
    await store.shutdown()
    XCTAssertTrue(store.subagentNotifiedRequests.isEmpty); XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
  }

  @MainActor func testActualChildToolApprovalHasApprovalAttentionAndExactProjectedNotificationTarget() async throws {
    let delivery = ChildRequestNotificationDelivery()
    let (store, task, run, child, request, log) = try await setup(mode: "tool", delivery: delivery)
    try await waitFor { store.subagentElicitations(taskID: task).count == 1 && delivery.notices.contains { $0.kind == .approval } }
    XCTAssertEqual(store.taskAttentionKind(for: try XCTUnwrap(store.library.tasks.first { $0.id == task })), .approval)
    let target = try XCTUnwrap(delivery.notices.first { $0.kind == .approval }?.destination)
    XCTAssertEqual(target.subagent?.requestToken, request.id); XCTAssertEqual(target.subagent?.childThreadID, child.threadID)
    let opened = await store.openNotification(target); XCTAssertTrue(opened)
    XCTAssertEqual(store.conversationReveal?.childRequestID, store.subagentElicitations(taskID: task).first?.id)
    await store.resolveSubagentElicitation(taskID: task, agent: child, request: request, choice: .decline, content: nil)
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    XCTAssertNil(store.taskAttentionKind(for: try XCTUnwrap(store.library.tasks.first { $0.id == task })))
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent MCP fixture complete")
  }
}
