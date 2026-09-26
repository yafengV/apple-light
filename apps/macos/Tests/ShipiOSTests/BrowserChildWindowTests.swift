import AppKit
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class BrowserChildWindowTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, BrowserTab, BrowserTab) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-window-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.selection = "a"; store.restoreWorkspaceTabLayout()
    store.newBrowserTab(in: .detached)
    let source = try XCTUnwrap(store.workspace.browser.selected)
    store.applyTaskSelection(store.library.tasks[1]); store.newBrowserTab()
    let main = try XCTUnwrap(store.workspace.browser.selected)
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); try? FileManager.default.removeItem(at: root)
    }
    return (store, source, main)
  }
  private func id(_ page: BrowserTab) -> String { "browser:\(page.id)" }

  func testDetachedFindCommandStaysWithItsOwnBrowserPage() throws {
    let (store, source, main) = try fixture()
    let commands = store.detachedWindowCommands(id(source), close: {})
    XCTAssertTrue(commands.execute("find"))
    XCTAssertTrue(source.showingPageFind)
    XCTAssertFalse(main.showingPageFind)
    XCTAssertFalse(store.showingFind)
    source.pageFindQuery = "query"
    let updated = store.detachedWindowCommands(id(source), close: {})
    XCTAssertTrue(updated.enabled.contains("find-next"))
  }

  func testNewCommandCreatesOwnedDetachedPageWithoutChangingMainTaskOrSelection() throws {
    let (store, source, main) = try fixture()
    let focus = store.focusComposer, layout = store.workspaceTabLayoutSnapshot
    let commands = store.detachedWindowCommands(id(source), close: {})
    XCTAssertTrue(commands.execute("browser-new"))
    let child = try XCTUnwrap(store.workspace.browser.tabs.last)
    XCTAssertNotEqual(child.id, main.id)
    XCTAssertEqual(store.workspaceTabs.first { $0.id == id(child) }?.owner, "a")
    XCTAssertEqual(store.workspaceTabPlacement(id(child)), .detached)
    XCTAssertEqual(store.workspace.browser.selection, main.id)
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout)
    XCTAssertEqual(store.workspace.browser.addressFocusTarget, child.id)
    let routes = store.takePendingDetachedWindowRoutes()
    XCTAssertEqual(routes, [.init(tabID: id(child), owner: "a", dataRoot: store.dataRoot)])
    XCTAssertTrue(store.takePendingDetachedWindowRoutes().isEmpty)
  }

  func testChildOfChildKeepsSourceOwnerAndWebKitConfiguration() throws {
    let (store, source, main) = try fixture()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let child = try XCTUnwrap(source.openWindow?(config))
    let grandchild = try XCTUnwrap(child.openWindow?(config))
    XCTAssertTrue(child.view.configuration.websiteDataStore === config.websiteDataStore)
    XCTAssertEqual(store.workspaceTabs.filter { $0.owner == "a" }.count, 3)
    XCTAssertEqual(store.workspaceTabPlacement(id(grandchild)), .detached)
    XCTAssertEqual(store.workspace.browser.selection, main.id)
    XCTAssertEqual(store.takePendingDetachedWindowRoutes().count, 2)
  }

  func testAttachedPageChildInheritsPaneAndCanActivateWithinItsOwner() throws {
    let (store, source, _) = try fixture()
    store.applyTaskSelection(store.library.tasks[0])
    store.moveWorkspaceTab(id(source), to: .right)
    let child = try XCTUnwrap(store.workspace.browser.newChildTab(from: source.id))
    XCTAssertEqual(store.workspaceTabPlacement(id(child)), .right)
    XCTAssertEqual(store.activeRightWorkspaceTabID, id(child))
    XCTAssertEqual(store.workspace.browser.selection, child.id)
    XCTAssertTrue(store.takePendingDetachedWindowRoutes().isEmpty)
  }

  func testBackgroundAddressEditsPersistWithoutLosingUnvisitedSavedTabs() throws {
    let (store, source, _) = try fixture()
    let child = try XCTUnwrap(store.workspace.browser.newChildTab(from: source.id))
    source.address = "parent address draft"; child.address = "child address draft"
    let untouched = SavedWorkspaceTab(id: "browser:\(UUID())", kind: .browser, placement: .left, address: "unvisited")
    store.library.workspaceTabLayouts["a"]?.tabs.append(untouched)
    store.saveLibrary()
    let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.tabs.first { $0.id == id(source) }?.address, source.address)
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.tabs.first { $0.id == id(child) }?.address, child.address)
    XCTAssertTrue(disk.workspaceTabLayouts["a"]?.tabs.contains(untouched) == true)
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    restored.library = disk; restored.libraryLoaded = true
    defer { restored.workspace.browser.shutdown() }
    XCTAssertNotNil(restored.prepareDetachedWorkspaceTab(.init(tabID: id(child), owner: "a", dataRoot: store.dataRoot)))
    XCTAssertEqual(restored.workspace.browser.tabs.first?.address, "child address draft")
  }

  func testScriptCloseRemovesOnlyChildAndCannotRestoreClosedSavedRoute() throws {
    let (store, source, main) = try fixture()
    let child = try XCTUnwrap(store.workspace.browser.newChildTab(from: source.id))
    let route = try XCTUnwrap(store.detachedWorkspaceTabRoute(id(child)))
    let focus = store.focusComposer
    child.closeWindow?()
    XCTAssertTrue(child.closed); XCTAssertFalse(source.closed); XCTAssertFalse(main.closed)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(route), .close)
    XCTAssertTrue(store.takePendingDetachedWindowRoutes().isEmpty)
    XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspace.browser.selection, main.id)
  }

  func testClosedDeletedAndQuittingSourcesCannotCreateOrQueueChildren() throws {
    let (store, source, _) = try fixture()
    let callback = try XCTUnwrap(source.openWindow)
    store.shuttingDown = true
    XCTAssertNil(callback(WKWebViewConfiguration()))
    store.shuttingDown = false
    store.library.tasks.removeAll { $0.id == "a" }
    XCTAssertNil(callback(WKWebViewConfiguration()))
    store.closeBrowserTab(source.id)
    XCTAssertNil(callback(WKWebViewConfiguration()))
    XCTAssertTrue(store.takePendingDetachedWindowRoutes().isEmpty)
  }
}
