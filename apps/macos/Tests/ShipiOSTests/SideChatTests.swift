import Foundation
import XCTest
@testable import ShipiOS

@MainActor final class SideChatTests: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func run(_ id: String, status: String) -> AgentRun {
    AgentRun(id: id, kind: "chat", project: "", status: status,
      createdAt: 1, updatedAt: 1,
      request: .object(["api_protocol": .string("codex_responses")]),
      result: .object(["response": .string(status == "succeeded" ? "Completed answer" : "Partial answer")]))
  }

  func testSideChatSnapshotsCompletedContextWithoutChangingParent() throws {
    let store = WorkspaceStore(dataRoot: try root())
    store.libraryLoaded = true
    let completed = run("completed", status: "succeeded")
    let active = run("active", status: "running")
    let parent = WorkspaceTask(id: UUID().uuidString, project: "", title: "Parent", runIDs: [completed.id, active.id])
    store.library.tasks = [parent]
    store.library.chatRuns = [completed, active]
    store.library.notes[completed.id] = "Original question"
    store.runs = [completed, active]
    store.selection = completed.id

    let side = try store.createSideChat(from: parent.id, prompt: "Why?")
    XCTAssertEqual(store.selection, completed.id)
    XCTAssertEqual(store.library.tasks.first(where: { $0.id == parent.id }), parent)
    XCTAssertEqual(side.sideChatParentID, parent.id)
    XCTAssertEqual(side.sideChatSourceRunIDs, [completed.id])
    XCTAssertEqual(store.library.drafts[side.id], "Why?")
    XCTAssertEqual(store.library.chatContext(taskID: side.id).map(\.content),
      ["Original question", "Completed answer"])
    XCTAssertFalse(store.library.visible(project: "", query: "", archived: false).contains(side))
    XCTAssertFalse(CommandMenuSearch.recent(library: store.library, currentID: parent.id)
      .contains(where: { $0.task.id == side.id }))
    XCTAssertFalse(store.canOpenSideChat(from: side.id), "Side chats cannot be nested")
    XCTAssertEqual(SideChatCommand.prompt(in: "/side Explain this"), "Explain this")
    XCTAssertEqual(SideChatCommand.prompt(in: "/side"), "")
    XCTAssertNil(SideChatCommand.prompt(in: "/sidebar"))
  }

  func testClosingAndRestoringDiscardTemporarySideChats() async throws {
    let root = try root()
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let parent = WorkspaceTask(id: UUID().uuidString, project: "", title: "Parent", runIDs: [])
    store.library.tasks = [parent]
    let side = try store.createSideChat(from: parent.id)
    await store.closeSideChat(side.id)
    XCTAssertFalse(store.library.tasks.contains(where: { $0.id == side.id }))
    XCTAssertTrue(store.library.tasks.contains(where: { $0.id == parent.id }))

    let stranded = try store.createSideChat(from: parent.id)
    let restarted = WorkspaceStore(dataRoot: root)
    restarted.library = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    restarted.libraryLoaded = true
    XCTAssertTrue(restarted.library.tasks.contains(where: { $0.id == stranded.id }))
    restarted.discardRestoredSideChats()
    XCTAssertFalse(restarted.library.tasks.contains(where: { $0.id == stranded.id }))
    XCTAssertTrue(restarted.library.tasks.contains(where: { $0.id == parent.id }))
  }
}
