import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowDropTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, TaskWindowResources, TaskWindowTabs) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-drop-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "popup", project: root.path, title: "Popup", runIDs: [])]
    store.selection = "main"
    store.library.drafts["main"] = "Main draft"
    let resources = TaskWindowResources()
    resources.prepare("popup", store: store)
    return (store, resources, try XCTUnwrap(resources.tasks["popup"]))
  }

  func testBrowserDropRevealsHiddenSideWithoutRecreatingPageOrChangingMainTask() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let id = try XCTUnwrap(tabs.focusedID), browser = try XCTUnwrap(tabs.browser.session.selected)
    browser.address = "unfinished address"
    tabs.beginDrag(id)
    XCTAssertTrue(tabs.canDropDraggedTab(to: .right))
    XCTAssertFalse(tabs.canDropDraggedTab(to: .bottom))
    XCTAssertFalse(tabs.showingRight)
    tabs.targetDrop(.right, entered: true)
    XCTAssertEqual(tabs.dropPlacement, .right)
    XCTAssertTrue(tabs.drop([tabs.dragToken(id)], to: .right))
    XCTAssertTrue(tabs.showingRight)
    XCTAssertEqual(tabs.placement(id), .right)
    XCTAssertEqual(tabs.focusedID, id)
    XCTAssertTrue(tabs.browser.session.selected === browser)
    XCTAssertEqual(browser.address, "unfinished address")
    XCTAssertNil(tabs.dragSessionID)
    XCTAssertNil(tabs.dropPlacement)
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["main"], "Main draft")
  }

  func testTerminalDropRevealsHiddenBottomAndPreservesPTY() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newTerminal(in: .left)
    let id = try XCTUnwrap(tabs.focusedID), terminal = try XCTUnwrap(tabs.panels.terminal)
    let pid = terminal.view.process.shellPid
    XCTAssertFalse(tabs.showingBottom)
    tabs.beginDrag(id)
    XCTAssertTrue(tabs.canDropDraggedTab(to: .bottom))
    tabs.targetDrop(.bottom, entered: true)
    XCTAssertTrue(tabs.drop([tabs.dragToken(id)], to: .bottom))
    XCTAssertTrue(tabs.showingBottom)
    XCTAssertTrue(tabs.panels.terminal === terminal)
    XCTAssertEqual(terminal.view.process.shellPid, pid)
    XCTAssertTrue(terminal.view.process.running)
    XCTAssertNil(tabs.draggingTabID)
  }

  func testRejectedAndForeignDropsDoNotCreateOrMoveContent() throws {
    let (store, resources, tabs) = try fixture()
    let other = TaskWindowResources()
    defer { resources.shutdown(); other.shutdown() }
    other.prepare("popup", store: store)
    let second = try XCTUnwrap(other.tasks["popup"])
    tabs.newBrowser()
    let id = try XCTUnwrap(tabs.focusedID)
    tabs.beginDrag(id)
    tabs.targetDrop(.bottom, entered: true)
    XCTAssertNil(tabs.dropPlacement)
    XCTAssertFalse(tabs.drop([tabs.dragToken(id)], to: .bottom))
    XCTAssertFalse(tabs.showingBottom)
    XCTAssertEqual(tabs.placement(id), .left)
    XCTAssertFalse(second.drop([tabs.dragToken(id)], to: .right))
    XCTAssertTrue(second.tabs.isEmpty)
    XCTAssertFalse(tabs.drop(["unrelated text"], to: .right))
    XCTAssertFalse(tabs.drop([tabs.dragToken(id)], to: .detached))
    XCTAssertEqual(tabs.tabs.count, 1)
  }

  func testLateExitAndOldReleaseCannotClearCurrentDragTarget() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newTerminal(in: .left)
    let id = try XCTUnwrap(tabs.focusedID)
    tabs.beginDrag(id)
    let old = try XCTUnwrap(tabs.dragSessionID)
    tabs.targetDrop(.right, entered: true)
    tabs.targetDrop(.bottom, entered: true)
    tabs.targetDrop(.right, entered: false)
    XCTAssertEqual(tabs.dropPlacement, .bottom)
    tabs.beginDrag(id)
    let new = try XCTUnwrap(tabs.dragSessionID)
    tabs.targetDrop(.right, entered: true)
    tabs.endDrag(session: old)
    XCTAssertEqual(tabs.dragSessionID, new)
    XCTAssertEqual(tabs.dropPlacement, .right)
    tabs.endDrag(session: new)
    XCTAssertNil(tabs.draggingTabID)
    XCTAssertNil(tabs.dropPlacement)
    XCTAssertEqual(tabs.placement(id), .left)
  }

  func testSourceCloseAndProjectResetClearPendingDropState() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let id = try XCTUnwrap(tabs.focusedID)
    tabs.beginDrag(id)
    tabs.targetDrop(.right, entered: true)
    tabs.close(id)
    XCTAssertNil(tabs.dragSessionID)
    XCTAssertNil(tabs.dropPlacement)
    tabs.beginDrag(id)
    XCTAssertNil(tabs.draggingTabID)
    tabs.openReview(defaultScope: .unstaged)
    tabs.beginDrag(try XCTUnwrap(tabs.focusedID))
    tabs.resetProjectTabs()
    XCTAssertNil(tabs.draggingTabID)
    XCTAssertNil(tabs.dragSessionID)
  }

  func testDropOverFilesReplacesPanelWithoutLosingBrowser() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let id = try XCTUnwrap(tabs.focusedID), browser = tabs.browser.session.selected
    tabs.panels.showingFiles = true
    tabs.beginDrag(id)
    XCTAssertTrue(tabs.drop([tabs.dragToken(id)], to: .right))
    XCTAssertFalse(tabs.panels.showingFiles)
    XCTAssertTrue(tabs.showingRight)
    XCTAssertTrue(tabs.browser.session.selected === browser)
  }
}
