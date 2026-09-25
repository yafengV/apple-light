import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class DetachedWorkspaceTabTests: XCTestCase {
  private func fixture(project: Bool = false) throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-tab-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    let scope = project ? root : nil
    store.project = scope; store.connected = project; store.scopeLoaded = true
    store.workspace.setProject(scope)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "a", project: scope?.path ?? "", title: "A", runIDs: []),
      .init(id: "b", project: scope?.path ?? "", title: "B", runIDs: [])]
    store.library.drafts = ["a": "A draft", "b": "B draft", "new:none": "Unsent draft"]
    store.selection = "a"
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }

  private func detachedBrowser(_ store: WorkspaceStore) throws -> WorkspaceContentTab {
    store.newBrowserTab()
    let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.moveWorkspaceTab(tab.id, to: .detached)
    store.saveLibrary()
    return tab
  }

  func testClosingInactiveOwnersWindowReturnsSameBrowserAndPersistsWithoutChangingMain() throws {
    let store = try fixture(), tab = try detachedBrowser(store)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    store.applyTaskSelection(store.library.tasks[1])
    store.newBrowserTab()
    let current = store.activeWorkspaceTabID
    let focus = store.focusComposer
    let before = store.workspaceTabLayoutSnapshot
    page.address = "updated while detached"
    store.restoredDetachedWorkspaceTabIDs = [tab.id]
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertEqual(store.selection, "b")
    XCTAssertEqual(store.activeWorkspaceTabID, current)
    XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, before)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .left)
    XCTAssertTrue(store.restoredDetachedWorkspaceTabIDs.isEmpty)
    let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.tabs.first?.placement, .left)
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.tabs.first?.address, "updated while detached")
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.active, tab.id)
    store.applyTaskSelection(store.library.tasks[0])
    XCTAssertEqual(store.activeWorkspaceTabID, tab.id)
    XCTAssertTrue(store.workspace.browser.selected === page)
    XCTAssertFalse(page.closed)
    XCTAssertTrue(store.restoredDetachedWorkspaceTabIDs.isEmpty)
  }

  func testClosingInactiveTerminalWindowKeepsItsProcessAndTask() throws {
    let store = try fixture(project: true)
    store.newTerminalTab(in: .bottom)
    let tab = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let session = try XCTUnwrap(store.terminalSession(try XCTUnwrap(tab.terminalID)))
    let pid = session.view.process.shellPid
    store.moveWorkspaceTab(tab.id, to: .detached)
    store.applyTaskSelection(store.library.tasks[1])
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertEqual(store.currentWorkspaceTabOwner, "b")
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .left)
    XCTAssertTrue(store.terminalSession(session.id) === session)
    XCTAssertTrue(session.view.process.running)
    XCTAssertEqual(session.view.process.shellPid, pid)
    store.applyTaskSelection(store.library.tasks[0])
    XCTAssertEqual(store.activeWorkspaceTabID, tab.id)
  }

  func testShutdownDoesNotReattachWindowsAndRepeatedCloseCannotChangeSelection() throws {
    let store = try fixture(), tab = try detachedBrowser(store)
    store.shuttingDown = true
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .detached)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.tabs.first?.placement, .detached)
    store.shuttingDown = false
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertEqual(store.activeWorkspaceTabID, tab.id)
    store.activateChatTab()
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertNil(store.activeWorkspaceTabID)
  }

  func testFocusChatReturnsToDetachedTabOwnerAndPreservesBothDraftsAndPage() async throws {
    let store = try fixture(), tab = try detachedBrowser(store)
    let page = store.workspace.browser.selected
    store.applyTaskSelection(store.library.tasks[1])
    store.openSettings(.general)
    XCTAssertTrue(store.canFocusDetachedWorkspaceChat(tab.id))
    let result = await store.focusDetachedWorkspaceChat(tab.id)
    XCTAssertTrue(result)
    XCTAssertEqual(store.selectedTask?.id, "a")
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertNil(store.focusedWorkspaceTabID)
    XCTAssertEqual(store.library.drafts["a"], "A draft")
    XCTAssertEqual(store.library.drafts["b"], "B draft")
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .detached)
    XCTAssertTrue(store.workspace.browser.tabs.first === page)
  }

  func testFocusChatReturnsToUnsentTaskWithoutCreatingOrClearingDraft() async throws {
    let store = try fixture()
    store.newTask(recordHistory: false)
    let tab = try detachedBrowser(store)
    store.applyTaskSelection(store.library.tasks[1])
    let result = await store.focusDetachedWorkspaceChat(tab.id)
    XCTAssertTrue(result)
    XCTAssertEqual(store.currentWorkspaceTabOwner, "new:none")
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertEqual(store.library.drafts["new:none"], "Unsent draft")
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .detached)
  }

  func testMissingOwnerBusyAndAlreadyReattachedTabsCannotNavigate() async throws {
    let store = try fixture(), tab = try detachedBrowser(store)
    store.applyTaskSelection(store.library.tasks[1])
    store.busy = true
    XCTAssertFalse(store.canFocusDetachedWorkspaceChat(tab.id))
    let busy = await store.focusDetachedWorkspaceChat(tab.id)
    XCTAssertFalse(busy)
    store.busy = false
    store.library.tasks.removeAll { $0.id == "a" }
    let missing = await store.focusDetachedWorkspaceChat(tab.id)
    XCTAssertFalse(missing)
    XCTAssertEqual(store.selection, "b")
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertFalse(store.canFocusDetachedWorkspaceChat(tab.id))
    XCTAssertFalse(store.canFocusDetachedWorkspaceChat("missing"))
  }
}
