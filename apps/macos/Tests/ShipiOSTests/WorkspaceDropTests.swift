import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceDropTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-drop-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.project = root
    store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
    store.selection = "task"
    store.library.drafts["task"] = "Keep draft"
    store.showingInspector = false
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown()
      store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }

  func testBrowserDropRevealsSideAndPreservesIdentityAfterPaneSwap() throws {
    let store = try fixture()
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let browser = try XCTUnwrap(store.workspace.browser.selected)
    browser.address = "Address draft"
    store.swapWorkspacePanes()
    store.beginWorkspaceTabDrag(tab.id)
    XCTAssertTrue(store.canDropWorkspaceTab(to: .right))
    XCTAssertFalse(store.canDropWorkspaceTab(to: .bottom))
    XCTAssertTrue(store.dropWorkspaceTab([WorkspaceTabDragToken.encode(tab.id)], to: .right))
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .right)
    XCTAssertTrue(store.workspace.browser.selected === browser)
    XCTAssertEqual(browser.address, "Address draft")
    XCTAssertEqual(store.library.drafts["task"], "Keep draft")
    XCTAssertNil(store.workspaceTabDragSessionID)
    XCTAssertNil(store.draggingWorkspaceTabID)
  }

  func testTerminalDropToHiddenBottomPreservesProcess() throws {
    let store = try fixture()
    store.newTerminalTab(in: .left)
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let terminalID = try XCTUnwrap(tab.terminalID)
    let scope = try XCTUnwrap(store.terminalScope)
    let terminal = try XCTUnwrap(store.workspace.terminals.session(terminalID, for: scope))
    let pid = terminal.view.process.shellPid
    store.showingTerminal = false
    store.beginWorkspaceTabDrag(tab.id)
    XCTAssertTrue(store.canDropWorkspaceTab(to: .bottom))
    XCTAssertTrue(store.dropWorkspaceTab([WorkspaceTabDragToken.encode(tab.id)], to: .bottom))
    XCTAssertTrue(store.showingTerminal)
    XCTAssertTrue(store.workspace.terminals.session(terminalID, for: scope) === terminal)
    XCTAssertTrue(terminal.view.process.running)
    XCTAssertEqual(terminal.view.process.shellPid, pid)
  }

  func testRejectedDropsLeaveLayoutUnchangedAndClearFeedback() throws {
    let store = try fixture()
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.beginWorkspaceTabDrag(tab.id)
    store.workspaceTabDropTarget = .placement(.right)
    XCTAssertFalse(store.dropWorkspaceTab([WorkspaceTabDragToken.encode(tab.id)], to: .bottom))
    XCTAssertNil(store.workspaceTabDropTarget)
    XCTAssertFalse(store.showingTerminal)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .left)
    XCTAssertFalse(store.dropWorkspaceTab(["unrelated"], to: .right))
    store.destination = .settings
    store.beginWorkspaceTabDrag(tab.id)
    XCTAssertFalse(store.canDropWorkspaceTab(to: .right))
    XCTAssertFalse(store.dropWorkspaceTab([WorkspaceTabDragToken.encode(tab.id)], to: .right))
    XCTAssertFalse(store.showingInspector)
  }

  func testOldReleaseCannotEndNewSessionAndClosingSourceCleansUp() throws {
    let store = try fixture()
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.beginWorkspaceTabDrag(tab.id)
    let old = try XCTUnwrap(store.workspaceTabDragSessionID)
    store.beginWorkspaceTabDrag(tab.id)
    let current = store.workspaceTabDragSessionID
    store.workspaceTabDropTarget = .pin
    store.endWorkspaceTabDrag(session: old)
    XCTAssertEqual(store.workspaceTabDragSessionID, current)
    XCTAssertEqual(store.workspaceTabDropTarget, .pin)
    store.closeWorkspaceTab(tab.id)
    XCTAssertNil(store.workspaceTabDragSessionID)
    XCTAssertNil(store.workspaceTabDropTarget)
  }

  func testDragHasNoTenSecondExpiry() async throws {
    let store = try fixture()
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.beginWorkspaceTabDrag(tab.id)
    let session = store.workspaceTabDragSessionID
    try await Task.sleep(for: .seconds(10.2))
    XCTAssertEqual(store.draggingWorkspaceTabID, tab.id)
    XCTAssertEqual(store.workspaceTabDragSessionID, session)
    store.endWorkspaceTabDrag()
    XCTAssertNil(store.draggingWorkspaceTabID)
  }
}
