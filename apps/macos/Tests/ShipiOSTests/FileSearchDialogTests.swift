import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class FileSearchDialogTests: XCTestCase {
  func testDialogKeysLeaveTextEditingAndIMEToNativeEditor() throws {
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ text: String = "", marked: Bool = false) throws -> SearchDialogKeyboardBridge.Key? {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: text,
        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
      return SearchDialogKeyboardBridge.key(for: event, markedText: marked)
    }
    for code: UInt16 in [36, 53, 125, 126, 48] { XCTAssertNil(try key(code, marked: true)) }
    XCTAssertNil(try key(0, [], "a"))
    XCTAssertNil(try key(0, .command, "a"))
    XCTAssertNil(try key(6, .command, "z"))
    XCTAssertNil(try key(125, .option))
    XCTAssertEqual(try key(125), .move(1))
    XCTAssertEqual(try key(126), .move(-1))
    XCTAssertEqual(try key(36), .submit)
    XCTAssertEqual(try key(53), .cancel)
    XCTAssertEqual(try key(13, .command, "w"), .cancel)
    XCTAssertEqual(try key(48), .tab(reverse: false))
    XCTAssertEqual(try key(48, .shift), .tab(reverse: true))
  }

  func testSearchBlocksMainCommandsAndRestoresSelectedSourceFocus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.workspace.root = root
    store.workspace.selectedFile = "Source.swift"
    store.showPane("files")
    store.setOverlay(.fileSearch, presented: true)
    store.fileFocusAfterOverlay = (root, "Source.swift")
    for command in ["new", "pin", "send", "settings", "model", "files"] {
      XCTAssertFalse(store.commandEnabled(command), command)
    }
    XCTAssertFalse(store.mainMCPApprovalVisible)
    let originalFocus = store.workspace.fileFocusRequest
    store.setOverlay(.fileSearch, presented: false)
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.workspace.fileFocusRequest, originalFocus)
    XCTAssertNil(store.fileFocusAfterOverlay)
    await store.shutdown()
  }
}
