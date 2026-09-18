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

  func testAlternateWindowRoutesRevalidateStateAndPreserveMainSelectionAndOverlay() async {
    let store = await store()
    let popout = WorkspaceTask(id: "b", project: "", title: "Popout", runIDs: [])
    store.library.tasks.append(popout)
    store.library.drafts["b"] = "Popout draft"
    store.showingCommands = true
    var mode: TaskWindowSearchMode? = .commands
    var destination = popout.id
    let context = SearchDialogContext(currentTaskID: popout.id,
      commandEnabled: { mode == .commands && ["pin", "search"].contains($0) },
      performCommand: { id in
        if id == "search" { mode = .tasks }
        else { mode = nil; store.updateTask(popout.id, pin: true) }
      }, canSelectTask: { candidate in
        mode != nil && store.library.tasks.contains { $0.id == candidate.id }
      }, navigate: { destination = $0.id; mode = nil }, cancel: { mode = nil })
    context.execute("files")
    XCTAssertEqual(mode, .commands)
    context.execute("search")
    XCTAssertEqual(mode, .tasks)
    context.execute("pin") // A command result delivered after switching modes is stale.
    XCTAssertFalse(store.library.tasks[1].pinned)
    context.select(.init(id: "removed", project: "", title: "Removed", runIDs: []))
    XCTAssertEqual(mode, .tasks)
    context.select(store.library.tasks[0])
    XCTAssertEqual(destination, "a")
    XCTAssertNil(mode)
    context.select(popout)
    XCTAssertEqual(destination, "a")
    mode = .commands
    context.execute("pin")
    XCTAssertTrue(store.library.tasks[1].pinned)
    XCTAssertFalse(store.library.tasks[0].pinned)
    XCTAssertEqual(store.selectedTask?.id, "a")
    XCTAssertEqual(store.presentedOverlay, .commands)
    XCTAssertEqual(store.library.drafts["a"], "Keep draft")
    XCTAssertEqual(store.library.drafts["b"], "Popout draft")
    await store.shutdown()
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
