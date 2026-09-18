import AppKit
import XCTest
@testable import ShipiOS

final class TaskRenameTests: XCTestCase {
  @MainActor func testRenamePersistsOnlyTargetWithoutChangingSelectionOrDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.library.drafts = ["a": "Main draft", "b": "Popout draft"]
    store.selectTask(store.library.tasks[0])
    try store.renameTask("b", title: "  新名称  \n")
    XCTAssertEqual(store.library.tasks[0].title, "A")
    XCTAssertEqual(store.library.tasks[1].title, "新名称")
    XCTAssertEqual(store.selectedTask?.id, "a")
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.library.tasks.first { $0.id == "b" }?.title, "新名称")
    XCTAssertEqual(restored.library.drafts["a"], "Main draft")
    XCTAssertEqual(restored.library.drafts["b"], "Popout draft")
    await store.shutdown(); await restored.shutdown()
  }

  @MainActor func testFailedWriteAndInvalidTargetPreserveTitleAndAllowRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "a", project: "", title: "Original", runIDs: [])]
    try store.renameTask("a", title: "Before")
    XCTAssertThrowsError(try store.renameTask("missing", title: "New"))
    XCTAssertThrowsError(try store.renameTask("a", title: " \n "))
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.renameTask("a", title: "After"))
    XCTAssertEqual(store.library.tasks[0].title, "Before")
    try FileManager.default.removeItem(at: file)
    try store.renameTask("a", title: "After")
    XCTAssertEqual(store.library.tasks[0].title, "After")
    await store.shutdown()
  }

  @MainActor func testMainRenameBlocksBackgroundCommandsAndApprovals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "a", project: "", title: "Original", runIDs: [])]
    store.selectTask(store.library.tasks[0])
    store.beginRenamingTask("a")
    for command in ["new", "rename", "pin", "send", "settings", "model"] {
      XCTAssertFalse(store.commandEnabled(command), command)
    }
    XCTAssertFalse(store.mainMCPApprovalVisible)
    store.executeCommand("pin")
    XCTAssertFalse(store.library.tasks[0].pinned)
    await store.shutdown()
  }

  @MainActor func testTextInputAndIMEAreNotConsumedByDialogKeyboard() throws {
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ characters: String = "", marked: Bool = false) throws -> RenameDialogKeyboardBridge.Key? {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
      return RenameDialogKeyboardBridge.key(for: event, markedText: marked)
    }
    XCTAssertNil(try key(49, [], " "))
    XCTAssertNil(try key(36, [], "\r", marked: true))
    XCTAssertNil(try key(53, [], "", marked: true))
    XCTAssertEqual(try key(48), .tab(reverse: false))
    XCTAssertEqual(try key(48, .shift), .tab(reverse: true))
    XCTAssertEqual(try key(36), .submit)
    XCTAssertEqual(try key(13, .command, "w"), .cancel)
    XCTAssertNil(try key(0, .command, "a"))
  }
}
