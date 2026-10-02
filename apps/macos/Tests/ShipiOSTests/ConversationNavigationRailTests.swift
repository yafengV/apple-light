import SwiftUI
import XCTest

@testable import ShipiOS

final class ConversationNavigationRailTests: XCTestCase {
  func testSelectionFollowsVisiblePromptAndScrubBounds() {
    XCTAssertEqual(ConversationRailSelection.current(
      positions: ["first": -250, "second": 90, "third": 420],
      orderedIDs: ["first", "second", "third"]), "second")
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: -20,
      orderedIDs: ["first", "second"]), "first")
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: 100,
      orderedIDs: ["first", "second"]), "second")
    XCTAssertNil(ConversationRailSelection.scrubbedID(y: 0, orderedIDs: []))
  }

  @MainActor func testPromptAndSteeredMessageBookmarksPersistAndDeleteWithTask() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-rail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let message = QueuedMessage(taskID: "task", text: "后续问题")
    let steered = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([message]))
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded",
      createdAt: 1_000, updatedAt: 1_000, request: .null,
      result: .object([
        "codex_steered_messages": steered,
        "response_items": try ChatResponseItem.json([.user(message.id)]),
      ]))
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "首条问题"
    store.library.tasks = [WorkspaceTask(id: "task", project: "", title: "会话", runIDs: [run.id])]
    let items = store.conversationRailItems(for: [run])
    let steeredID = ConversationRailItem.steeredID(runID: run.id, messageID: message.id)
    XCTAssertEqual(items.map(\.id), [run.id, steeredID])
    XCTAssertEqual(items.map(\.preview), ["首条问题", "后续问题"])
    XCTAssertTrue(store.setConversationBookmark(true, runID: run.id))
    XCTAssertTrue(store.setConversationBookmark(true, runID: steeredID))
    XCTAssertFalse(store.setConversationBookmark(true, runID: "unknown"))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.bookmarkedRunIDs, [run.id, steeredID])
    XCTAssertEqual(store.conversationRailItems(for: [run]).map(\.bookmarked), [true, true])
    var deleted = restored
    deleted.tasks[0].archived = true
    XCTAssertEqual(deleted.deleteArchivedTasks(["task"]), ["run"])
    XCTAssertTrue(deleted.bookmarkedRunIDs.isEmpty)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data("{}".utf8)).bookmarkedRunIDs.isEmpty)
  }

  @MainActor func testRailRendersWithoutForegroundWindow() {
    let item = ConversationRailItem(id: "run", title: "模型", preview: "问题",
      date: Date(timeIntervalSince1970: 0), bookmarked: true)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: ConversationRailOverlay(items: [item],
      currentID: item.id, onSelect: { _ in }, onBookmark: { _, _ in }))
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
    host.layoutSubtreeIfNeeded()
    XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
  }
}
