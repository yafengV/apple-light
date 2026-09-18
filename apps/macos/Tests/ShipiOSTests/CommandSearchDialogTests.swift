import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class CommandSearchDialogTests: XCTestCase {
  private func store() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "a", project: "", title: "First", runIDs: [])]
    store.library.drafts["a"] = "Keep draft"
    store.selectTask(store.library.tasks[0])
    return store
  }

  func testReturnFocusCapturesTextFieldInsteadOfSharedFieldEditor() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let original = NSTextField(frame: .init(x: 10, y: 100, width: 300, height: 24))
    let query = NSTextField(frame: .init(x: 10, y: 50, width: 300, height: 24))
    window.contentView?.addSubview(original)
    window.contentView?.addSubview(query)
    XCTAssertTrue(window.makeFirstResponder(original))
    let target = SearchDialogReturnFocus(window: window, destination: .settings)
    XCTAssertTrue(target.view === original)
    XCTAssertTrue(window.makeFirstResponder(query))
    XCTAssertTrue(target.view === original)
    XCTAssertTrue(target.window === window)
  }

  func testPaletteAllowsOnlyExplicitSelectionAndExecutesWithoutDelay() async {
    let store = await store()
    store.showingCommands = true
    XCTAssertFalse(store.commandEnabled("pin"))
    XCTAssertTrue(store.paletteCommandEnabled("pin"))
    store.executeCommand("pin")
    XCTAssertFalse(store.library.tasks[0].pinned)
    store.executePaletteCommand("pin")
    XCTAssertTrue(store.library.tasks[0].pinned)
    XCTAssertNil(store.presentedOverlay)
    XCTAssertEqual(store.library.drafts["a"], "Keep draft")
    // A stale click after dismissal must not execute a second action.
    store.executePaletteCommand("pin")
    XCTAssertTrue(store.library.tasks[0].pinned)
    await store.shutdown()
  }

  func testDisabledSelectionStaysOpenAndCanTransitionToAnotherDialog() async {
    let store = await store()
    store.showingCommands = true
    XCTAssertFalse(store.paletteCommandEnabled("files"))
    store.executePaletteCommand("files")
    XCTAssertEqual(store.presentedOverlay, .commands)
    store.fileFocusAfterOverlay = (store.dataRoot, "Original.swift")
    store.executePaletteCommand("search")
    XCTAssertEqual(store.presentedOverlay, .taskSearch)
    XCTAssertEqual(store.fileFocusAfterOverlay?.path, "Original.swift")
    XCTAssertFalse(store.commandEnabled("settings"))
    XCTAssertFalse(store.paletteCommandEnabled("settings"))
    store.executePaletteCommand("settings")
    XCTAssertEqual(store.presentedOverlay, .taskSearch)
    await store.shutdown()
  }

  func testPaletteSettingsNavigationDoesNotLeaveAnOverlayOrStaleSourceFocus() async {
    let store = await store()
    store.showingCommands = true
    store.fileFocusAfterOverlay = (store.dataRoot, "Old.swift")
    store.executePaletteCommand("settings")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertNil(store.presentedOverlay)
    XCTAssertNil(store.fileFocusAfterOverlay)
    await store.shutdown()
  }
}
