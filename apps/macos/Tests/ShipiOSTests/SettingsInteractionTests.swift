import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class SettingsInteractionTests: XCTestCase {
  @MainActor func testFindStaysInEverySettingsPageAndPreservesReturnLocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.showProjects()
    store.library.drafts["new:none"] = "原草稿"
    store.openSettings()
    for page in SettingsNavigation.pages {
      store.settingsPage = page
      let before = store.settingsSearchFocusRequest
      XCTAssertTrue(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘F"))))
      XCTAssertNotEqual(store.settingsSearchFocusRequest, before)
      XCTAssertEqual(store.destination, .settings)
      XCTAssertEqual(store.settingsPage, page)
      XCTAssertFalse(store.showingFind)
      XCTAssertNil(store.presentedOverlay)
    }
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    XCTAssertEqual(store.library.drafts["new:none"], "原草稿")
    store.executeCommand("find")
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertTrue(store.showingFind)
  }

  @MainActor func testFindRespectsCustomBindingsAndModalCapture() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.git)
    try store.shortcuts.set(nil, for: "workspace-view")
    try store.shortcuts.set(ShortcutBinding("⌘⇧F"), for: "find")
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘F"))))
    XCTAssertTrue(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘⇧F"))))
    let before = store.settingsSearchFocusRequest
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘⇧F"))))
    store.shortcutCaptureCount = 0
    store.presentedOverlay = .commands
    XCTAssertFalse(store.handleWorkspaceShortcut(try XCTUnwrap(ShortcutBinding("⌘⇧F"))))
    XCTAssertEqual(store.settingsSearchFocusRequest, before)
    store.presentedOverlay = nil
    store.executeCommand("find") // The menu uses the same destination-aware action.
    XCTAssertNotEqual(store.settingsSearchFocusRequest, before)
    XCTAssertEqual(store.destination, .settings)
  }

  @MainActor func testSearchEditorClearsEscapeConsumesEmptyEscapeAndRoutesNavigation() {
    var query = "浏览器"
    var moves: [MoveCommandDirection] = []
    var submitted = 0
    let view = SettingsSearchInput(query: Binding(get: { query }, set: { query = $0 }),
      focusRequest: UUID(), visible: true, onMove: { moves.append($0) },
      onSubmit: { submitted += 1 })
    let coordinator = view.makeCoordinator()
    let field = NSSearchField()
    let editor = NSTextView()
    field.stringValue = "Git"
    coordinator.searchChanged(field)
    XCTAssertEqual(query, "Git")
    field.stringValue = ""
    coordinator.searchChanged(field)
    XCTAssertEqual(query, "")
    query = "浏览器"
    field.stringValue = query
    XCTAssertTrue(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(query, "")
    XCTAssertEqual(field.stringValue, "")
    XCTAssertTrue(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertTrue(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.moveDown(_:))))
    XCTAssertTrue(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.moveUp(_:))))
    XCTAssertTrue(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertEqual(moves, [.down, .up])
    XCTAssertEqual(submitted, 1)
    XCTAssertFalse(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.moveLeft(_:))))
    editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertFalse(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertFalse(coordinator.control(field, textView: editor,
      doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    XCTAssertEqual(submitted, 1)
  }
}
