import XCTest
@testable import ShipiOS

final class CodexPlanDocumentTests: XCTestCase {
  private func event(type: String = "item_completed", itemType: String = "plan", text: String = "# Release plan\nShip the app") -> JSONValue {
    .object([
      "type": .string(type),
      "item": .object(["type": .string(itemType), "id": .string("plan-1"), "text": .string(text)]),
    ])
  }

  func testCompletedPlanItemIsDistinctFromProgressAndOtherItems() {
    let document = CodexPlanDocument.completed(event())
    XCTAssertEqual(document?.id, "plan-1")
    XCTAssertEqual(document?.title, "Release plan")
    XCTAssertNil(CodexPlanDocument.completed(event(type: "item_started")))
    XCTAssertNil(CodexPlanDocument.completed(event(itemType: "agentMessage")))
    XCTAssertNil(CodexPlanDocument.completed(event(type: "plan_update")))
  }

  @MainActor func testDocumentSurvivesSubsequentResponseUpdates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "running",
      createdAt: 0, updatedAt: 0, request: .null, result: .object(["response": .string("")]))
    store.runs = [run]
    store.library.chatRuns = [run]
    let document = try XCTUnwrap(CodexPlanDocument.completed(event()))
    store.replaceChat(run, status: "running", response: "", codexPlanDocument: document)
    let updated = try XCTUnwrap(store.library.chatRuns.first)
    XCTAssertEqual(updated.codexPlanDocument, document)
    store.replaceChat(updated, status: "succeeded", response: "Completed")
    XCTAssertEqual(store.library.chatRuns.first?.codexPlanDocument, document)
  }

  @MainActor func testPlanTabBelongsToItsTaskAndRestoresAsPlan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let document = try XCTUnwrap(CodexPlanDocument.completed(event()))
    let result = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(document))
    let run = AgentRun(id: "run-plan", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["codex_plan_document": result, "response": .string("")]))
    let owner = WorkspaceTask(id: "owner", project: "", title: "Owner", runIDs: [run.id])
    let other = WorkspaceTask(id: "other", project: "", title: "Other", runIDs: [])
    store.library.tasks = [owner, other]
    store.library.chatRuns = [run]
    store.runs = [run]
    store.selectTask(owner)
    XCTAssertTrue(store.openPlanDocument(runID: run.id))
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertEqual(tab, .plan(run.id, owner: owner.id))
    XCTAssertEqual(store.workspaceTabTitle(tab), "Release plan")
    XCTAssertEqual(store.workspaceTabLayoutSnapshot.tabs.first?.kind, .plan)
    store.closeWorkspaceTab(tab.id)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    store.pinWorkspaceTab(tab.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.kind, .plan)
    store.closeWorkspaceTab(tab.id)
    await store.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    store.selectTask(other)
    XCTAssertFalse(store.openPlanDocument(runID: run.id))
    await store.shutdown()
  }
}
