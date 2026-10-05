import XCTest
import SwiftUI
import CryptoKit
@testable import ShipiOS

@MainActor final class ChildRequestNotificationDelivery: NotificationDelivery {
  var notices: [CompletionNotice] = []
  var onPermission: (() -> Void)?
  func permission() async -> NotificationPermission { onPermission?(); return .authorized }
  func requestPermission() async throws { XCTFail("Tests must not request system permission") }
  func post(_ notice: CompletionNotice) async throws { notices.append(notice) }
}

@MainActor final class SubagentAttentionTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, CodexSubagent, String, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-attention-\(UUID())")
    let store = WorkspaceStore(dataRoot: root); await store.restore()
    addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 1, updatedAt: 2, request: .null, result: nil)
    let parent = UUID().uuidString, child = UUID().uuidString, token = UUID().uuidString
    let agent = CodexSubagent(rootThreadID: parent, threadID: child, nickname: "Child", status: .running, loaded: true, observedAtMs: 1)
    var task = WorkspaceTask(id: "task", project: "", title: "Parent", runIDs: [run.id]); task.codexThreadID = parent; task.codexSubagents = [agent]
    store.library.tasks = [task]; store.library.chatRuns = [run]; store.runs = [run]; store.selection = run.id
    var live = SubagentLiveState()
    live.receiveElicitation(state(child: child, token: token, revision: 1, phase: "pending"), child: child)
    let event: JSONValue = .object(["type": .string("elicitation_request"), "turn_id": .null,
      "server_name": .string("fixture"), "id": .string("request"), "shipios_elicitation": .object([
        "token": .string(token), "turnId": .string("child-turn"), "choices": .array([.string("accept"), .string("decline"), .string("cancel")])]),
      "request": .object(["mode": .string("form"), "message": .string("Child form"), "requested_schema": .object([
        "type": .string("object"), "properties": .object([:])])])])
    let bytes = try JSONEncoder().encode(event), text = String(decoding: bytes, as: UTF8.self)
    live.append(.object(["type": .string("shipios_subagent_event"), "childThreadId": .string(child),
      "streamId": .string(UUID().uuidString), "sequence": .number(1), "eventId": .string("event"),
      "offset": .number(0), "totalBytes": .number(Double(bytes.count)), "done": .bool(true), "chunk": .string(text),
      "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())]), child: child)
    store.subagentLiveStates[agent.id] = live
    return (store, agent, token, "task")
  }
  private func state(child: String, token: String, revision: Int, phase: String) -> JSONValue {
    .object(["type": .string("shipios_subagent_elicitation_state"), "childThreadId": .string(child),
      "turnId": .string("child-turn"), "requestToken": .string(token), "revision": .number(Double(revision)), "state": .string(phase)])
  }
  func testParentCompletionDoesNotHideChildAttentionAndResolutionRetiresIt() async throws {
    let (store, agent, token, task) = try await fixture()
    XCTAssertEqual(store.subagentElicitations(taskID: task).count, 1)
    XCTAssertEqual(store.taskAttentionKind(for: store.library.tasks[0]), .elicitation)
    XCTAssertEqual(store.petActivityStatus, .needsInput)
    store.toggleActivity(); XCTAssertEqual(store.activityPriorityEntries.map(\.id), [task])
    XCTAssertEqual(store.activityBadgeCount, 1); XCTAssertTrue(store.activityEntries[0].running)
    store.recordSubagentEvent(taskID: task, threadID: agent.rootThreadID, event: state(child: agent.threadID, token: token, revision: 2, phase: "resolving"))
    XCTAssertEqual(store.subagentElicitations(taskID: task).count, 1)
    XCTAssertNil(store.taskAttentionKind(for: store.library.tasks[0]))
    XCTAssertEqual(store.petActivityStatus, .running)
    store.recordSubagentEvent(taskID: task, threadID: agent.rootThreadID, event: state(child: agent.threadID, token: token, revision: 3, phase: "resolved"))
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    XCTAssertNil(store.taskAttentionKind(for: store.library.tasks[0]))
    store.library.tasks[0].codexSubagents?[0].status = .completed
    XCTAssertEqual(store.petActivityStatus, .idle)
  }
  func testChangedRootColdChildArchivedOwnerAndBrokenFramesCannotProjectRequests() async throws {
    let (store, agent, _, task) = try await fixture()
    store.library.tasks[0].codexThreadID = UUID().uuidString
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty); XCTAssertNil(store.subagentAttention(taskID: task))
    store.library.tasks[0].codexThreadID = agent.rootThreadID; store.library.tasks[0].codexSubagents?[0].loaded = false
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    store.library.tasks[0].codexSubagents?[0].loaded = true; store.library.tasks[0].archived = true
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty)
    XCTAssertNil(store.subagentAttention(taskID: task))
    store.library.tasks[0].archived = false
    var live = try XCTUnwrap(store.subagentLiveStates[agent.id]); live.append(.null, child: agent.threadID)
    store.subagentLiveStates[agent.id] = live
    XCTAssertTrue(store.subagentElicitations(taskID: task).isEmpty); XCTAssertNil(store.subagentAttention(taskID: task))
  }
  func testNotificationIsDeduplicatedAndContainsOnlyItsActualChildIdentity() async throws {
    let (store, agent, token, task) = try await fixture(), delivery = ChildRequestNotificationDelivery()
    store.notifications = CompletionNotificationCenter(delivery: delivery)
    store.notifySubagentRequests(taskID: task); store.notifySubagentRequests(taskID: task)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(delivery.notices.count, 1)
    let notice = try XCTUnwrap(delivery.notices.first), target = try XCTUnwrap(notice.destination)
    XCTAssertEqual(target.subagent, .init(rootThreadID: agent.rootThreadID, childThreadID: agent.threadID, requestToken: token))
    XCTAssertEqual(target.taskID, task); XCTAssertEqual(target.runID, "run")
    XCTAssertEqual(NotificationDestination(userInfo: target.userInfo), target)
  }
  func testPartialForeignOrMalformedChildNotificationIdentityIsRejected() {
    let root = UUID().uuidString, child = UUID().uuidString, token = UUID().uuidString
    let target = NotificationDestination(dataRoot: "/fixture", project: "", taskID: "task", runID: "run",
      subagent: .init(rootThreadID: root, childThreadID: child, requestToken: token))
    var info = target.userInfo; info.removeValue(forKey: "subagentThreadID")
    XCTAssertNil(NotificationDestination(userInfo: info))
    info = target.userInfo; info["subagentRequestToken"] = "invalid"
    XCTAssertNil(NotificationDestination(userInfo: info))
    info = target.userInfo; info["subagentThreadID"] = root
    XCTAssertNil(NotificationDestination(userInfo: info))
    XCTAssertNotNil(NotificationDestination(userInfo: ["dataRoot": "/fixture", "project": "", "taskID": "task", "runID": "run"]))
    info = target.userInfo; info["subagentThreadID"] = root.lowercased(); info["subagentRootThreadID"] = root.uppercased()
    XCTAssertNil(NotificationDestination(userInfo: info))
  }
  func testRequestEndingWhileNotificationPermissionIsReadSuppressesStaleAlert() async throws {
    let (store, agent, token, task) = try await fixture(), delivery = ChildRequestNotificationDelivery()
    store.notifications = CompletionNotificationCenter(delivery: delivery)
    var permissionRead = false
    delivery.onPermission = {
      permissionRead = true
      store.recordSubagentEvent(taskID: task, threadID: agent.rootThreadID,
        event: self.state(child: agent.threadID, token: token, revision: 2, phase: "resolved"))
    }
    store.notifySubagentRequests(taskID: task)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(permissionRead); XCTAssertTrue(delivery.notices.isEmpty)
    delivery.onPermission = nil
  }
  func testHiddenMainAndTaskTimelinesAndOwnedPendingFormRender() async throws {
    let (store, _, _, task) = try await fixture()
    let request = try XCTUnwrap(store.subagentElicitations(taskID: task).first)
    for width in [320.0, 760.0] {
      let host = NSHostingView(rootView: ProjectedSubagentElicitationView(store: store, taskID: task, presentation: request))
      host.frame = .init(x: 0, y: 0, width: width, height: 400); host.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
    let main = NSHostingView(rootView: ConversationTimelineView(store: store))
    main.frame = .init(x: 0, y: 0, width: 760, height: 600); main.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(main.fittingSize.height, 0)
    let resources = TaskWindowResources(); resources.prepare(task, store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks[task])
    let detached = NSHostingView(rootView: TaskWindowView(store: store, taskID: task, tabs: tabs,
      resources: resources, renameHistory: TaskRenameHistory(), onNavigate: { _ in },
      canGoBack: false, canGoForward: false, onMove: { _ in }))
    detached.frame = .init(x: 0, y: 0, width: 760, height: 600); detached.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(detached.fittingSize.height, 0)
  }
}
