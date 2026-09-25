import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class DetachedWindowSearchTests: XCTestCase {
  private final class TestWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func fixture() throws -> (WorkspaceStore, String, BrowserTab) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-search-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.selection = "a"; store.restoreWorkspaceTabLayout(); store.newBrowserTab(in: .detached)
    let source = try XCTUnwrap(store.workspace.browser.selected)
    store.applyTaskSelection(store.library.tasks[1]); store.newBrowserTab()
    store.library.drafts["a"] = "A draft"; store.library.drafts["b"] = "B draft"
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); try? FileManager.default.removeItem(at: root)
    }
    return (store, "browser:\(source.id)", source)
  }
  private func context(_ search: DetachedWindowSearch, store: WorkspaceStore, id: String,
    showMain: @escaping () -> Void = {}, showDetached: @escaping (WorkspaceTabWindowRoute) -> Void = { _ in }) -> SearchDialogContext {
    search.context(store: store, tabID: id, closeWindow: {}, showMain: showMain, showDetached: showDetached)
  }

  func testCommandsOpenLocalSearchWithoutChangingMainSelectionOrOverlay() throws {
    let (store, id, source) = try fixture(), search = DetachedWindowSearch()
    store.showingCommands = true
    let commands = search.commands(store: store, tabID: id, closeWindow: {})
    XCTAssertEqual(commands.command(for: ShortcutBinding("⌘K"), shortcuts: store.shortcuts), "palette")
    XCTAssertTrue(commands.execute("palette"))
    XCTAssertEqual(search.mode, .commands)
    XCTAssertTrue(search.commands(store: store, tabID: id, closeWindow: {}).enabled.isEmpty)
    let local = context(search, store: store, id: id)
    XCTAssertEqual(local.currentTaskID, "a")
    local.execute("browser-address")
    XCTAssertNil(search.mode)
    XCTAssertEqual(store.workspace.browser.addressFocusTarget, source.id)
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.presentedOverlay, .commands)
    XCTAssertEqual(store.library.drafts["a"], "A draft"); XCTAssertEqual(store.library.drafts["b"], "B draft")
  }

  func testModeSwitchAndStaleResultsCannotExecuteAfterCancelOrTaskRemoval() throws {
    let (store, id, _) = try fixture(), search = DetachedWindowSearch()
    search.open(.commands, window: nil)
    let local = context(search, store: store, id: id)
    local.execute("search")
    XCTAssertEqual(search.mode, .tasks)
    local.execute("browser-new")
    XCTAssertEqual(store.workspaceTabs.count, 2)
    let removed = store.library.tasks.removeFirst()
    local.select(removed)
    XCTAssertEqual(search.mode, .tasks); XCTAssertEqual(store.selection, "b")
    local.cancel()
    local.select(store.library.tasks[0]); local.execute("settings")
    XCTAssertNil(search.mode); XCTAssertEqual(store.destination, .workspace)
  }

  func testTaskResultNavigatesMainWhilePreservingDetachedOwnerAndDrafts() throws {
    let (store, id, _) = try fixture(), search = DetachedWindowSearch()
    var shown = 0
    search.open(.tasks, window: nil)
    context(search, store: store, id: id, showMain: { shown += 1 }).select(store.library.tasks[0])
    XCTAssertEqual(shown, 1); XCTAssertNil(search.mode)
    XCTAssertEqual(store.selection, "a")
    XCTAssertEqual(store.workspaceTabPlacement(id), .detached)
    XCTAssertEqual(store.library.drafts["a"], "A draft"); XCTAssertEqual(store.library.drafts["b"], "B draft")
  }

  func testSettingsUsesMainAndSearchNeverAllowsUnrelatedTaskMutation() throws {
    let (store, id, _) = try fixture(), search = DetachedWindowSearch()
    var shown = 0
    search.open(.commands, window: nil)
    let local = context(search, store: store, id: id, showMain: { shown += 1 })
    local.execute("pin")
    XCTAssertFalse(store.library.tasks.contains { $0.pinned })
    XCTAssertEqual(search.mode, .commands)
    local.execute("settings")
    XCTAssertEqual(store.destination, .settings); XCTAssertNil(search.mode); XCTAssertEqual(shown, 1)
    XCTAssertEqual(store.selection, "b")
  }

  func testDetachedBrowserResultRaisesExistingRouteWithoutMainNavigation() throws {
    let (store, id, source) = try fixture(), search = DetachedWindowSearch()
    let child = try XCTUnwrap(store.workspace.browser.newChildTab(from: source.id))
    var routes: [WorkspaceTabWindowRoute] = []
    var mainShown = false
    search.open(.commands, window: nil)
    let local = context(search, store: store, id: id, showMain: { mainShown = true }, showDetached: { routes.append($0) })
    XCTAssertEqual(local.browserResults.count, 3)
    let result = try XCTUnwrap(local.browserResults.first { $0.id == "browser:\(child.id)" })
    local.selectBrowser(result)
    XCTAssertEqual(routes, [.init(tabID: result.id, owner: "a", dataRoot: store.dataRoot)])
    XCTAssertFalse(mainShown); XCTAssertEqual(store.selection, "b"); XCTAssertNil(search.mode)
    local.selectBrowser(result)
    XCTAssertEqual(routes.count, 1)
  }

  func testClosedPageResultsAndRemovedSourceAreRevalidated() throws {
    let (store, id, source) = try fixture(), search = DetachedWindowSearch()
    let child = try XCTUnwrap(store.workspace.browser.newChildTab(from: source.id))
    search.open(.commands, window: nil)
    var shown = false
    let local = context(search, store: store, id: id, showDetached: { _ in shown = true })
    let result = try XCTUnwrap(local.browserResults.first { $0.id == "browser:\(child.id)" })
    store.closeBrowserTab(child.id)
    local.selectBrowser(result)
    XCTAssertFalse(shown); XCTAssertEqual(search.mode, .commands)
    store.closeBrowserTab(source.id)
    XCTAssertFalse(local.commandEnabled("settings")); XCTAssertFalse(local.canSelectTask(store.library.tasks[1]))
  }

  func testSearchModeChangeReturnsFocusToOriginalFieldRatherThanSharedQueryEditor() async throws {
    let search = DetachedWindowSearch()
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let address = NSTextField(frame: .init(x: 10, y: 100, width: 300, height: 24))
    let query = NSTextField(frame: .init(x: 10, y: 50, width: 300, height: 24))
    window.contentView?.addSubview(address); window.contentView?.addSubview(query)
    address.stringValue = "address draft"
    XCTAssertTrue(window.makeFirstResponder(address))
    search.open(.commands, window: window)
    XCTAssertTrue(window.makeFirstResponder(query))
    search.open(.tasks, window: window)
    search.close(); search.restoreFocus()
    for _ in 0..<40 {
      if address.currentEditor() != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(window.firstResponder === address.currentEditor())
    XCTAssertEqual(address.stringValue, "address draft")
  }
}
