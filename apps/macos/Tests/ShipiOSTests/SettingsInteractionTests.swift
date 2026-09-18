import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class SettingsInteractionTests: XCTestCase {
  @MainActor func testPageEscapeRoutesOutsideEditorsAndPreservesModalGuards() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let store = WorkspaceStore()
    store.showProjects()
    store.openSettings()
    let editor = NSTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
    window.contentView = editor
    window.makeFirstResponder(editor)
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    XCTAssertEqual(store.destination, .settings)
    editor.setMarkedText("pin", selectedRange: .init(location: 3, length: 0),
      replacementRange: .init(location: NSNotFound, length: 0))
    XCTAssertTrue(editor.hasMarkedText())
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    editor.unmarkText()
    window.makeFirstResponder(nil)
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    store.shortcutCaptureCount = 0
    store.presentedOverlay = .commands
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    store.presentedOverlay = nil
    store.shortcutResetRequested = true
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
    store.shortcutResetRequested = false
    XCTAssertTrue(store.closeSettingsFromKeyboard(in: window))
    XCTAssertEqual(store.destination, .projects)
    XCTAssertFalse(store.closeSettingsFromKeyboard(in: window))
  }

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
