import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class DetachedWorkspaceTabRestorationTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-restore-\(UUID())")
    let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
    for path in [a, b] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.library.tasks = [.init(id: "a", project: a.path, title: "A", runIDs: []),
      .init(id: "b", project: b.path, title: "B", runIDs: [])]
    store.project = b; store.workspace.setProject(b); store.selection = "b"
    store.library.drafts["a"] = "A draft"; store.library.drafts["b"] = "B draft"
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  private func save(_ tabs: [SavedWorkspaceTab], owner: String = "a", store: WorkspaceStore) {
    store.library.workspaceTabLayouts[owner] = .init(tabs: tabs, showingInspector: false,
      showingTerminal: false, showingTabs: true, side: .left, reviewScope: .staged)
  }
  private func route(_ id: String, store: WorkspaceStore) -> WorkspaceTabWindowRoute {
    .init(tabID: id, owner: "a", dataRoot: store.dataRoot)
  }

  func testRouteRoundTripCanonicalIdentityAndLegacyDecoding() throws {
    let store = try fixture()
    let value = route("review:a", store: store)
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceTabWindowRoute.self, from: JSONEncoder().encode(value)), value)
    XCTAssertNotEqual(value, WorkspaceTabWindowRoute(tabID: value.tabID, owner: "a", dataRoot: store.dataRoot.appendingPathComponent("other")))
    XCTAssertNotEqual(value, WorkspaceTabWindowRoute(tabID: value.tabID, owner: "b", dataRoot: store.dataRoot))
    let link = store.dataRoot.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: store.dataRoot)
    XCTAssertEqual(value, WorkspaceTabWindowRoute(tabID: value.tabID, owner: "a", dataRoot: link))
    let legacy = try JSONDecoder().decode(WorkspaceTabWindowRoute.self, from: Data(#"{"tabID":"review:a"}"#.utf8))
    XCTAssertNil(legacy.owner); XCTAssertNil(legacy.dataRoot)
  }

  func testForeignRootCannotReadOrCreateCollidingTabEvenDuringLoading() throws {
    let store = try fixture()
    save([.init(id: "review:a", kind: .review, placement: .detached)], store: store)
    let foreign = WorkspaceTabWindowRoute(tabID: "review:a", owner: "a", dataRoot: store.dataRoot.appendingPathComponent("other"))
    store.libraryLoaded = false; store.restoringLibrary = true
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(foreign), .close)
    XCTAssertNil(store.prepareDetachedWorkspaceTab(foreign))
    XCTAssertTrue(store.workspaceTabs.isEmpty)
  }

  func testPendingRouteAndLibraryLoadDoNotPrematurelyCloseWindow() throws {
    let store = try fixture(), value = route("review:a", store: store)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(nil), .loading)
    store.libraryLoaded = false
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .loading)
    store.libraryReadError = "Cannot read workspace"
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .failed("Cannot read workspace"))
    store.restoringLibrary = true
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .loading)
    store.restoringLibrary = false; store.libraryLoaded = true; store.libraryReadError = nil
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .close)
  }

  func testBackgroundMixedResourcesRestoreWithoutMainNavigationAndReuseOnOwnerVisit() throws {
    let store = try fixture(), browserID = UUID(), terminalID = UUID()
    let saved: [SavedWorkspaceTab] = [
      .init(id: "review:a", kind: .review, placement: .detached),
      .init(id: "browser:\(browserID)", kind: .browser, placement: .detached, address: "unfinished address"),
      .init(id: "terminal:\(terminalID)", kind: .terminal, placement: .detached)]
    save(saved, store: store)
    let focus = store.focusComposer, layout = store.workspaceTabLayoutSnapshot
    for entry in saved {
      let value = route(entry.id, store: store)
      XCTAssertEqual(store.prepareDetachedWorkspaceTab(value), value)
      XCTAssertEqual(store.prepareDetachedWorkspaceTab(value), value)
    }
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.focusComposer, focus)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout)
    XCTAssertEqual(store.workspace.reviewScope, .unstaged)
    XCTAssertEqual(store.workspaceTabs.count, 3)
    let browser = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == browserID })
    XCTAssertEqual(browser.address, "unfinished address"); XCTAssertNil(browser.committedURL)
    let terminal = try XCTUnwrap(store.terminalSession(terminalID))
    XCTAssertEqual(store.terminalScope(for: .terminal(terminalID, owner: "a"))?.project, store.workspaceTabProject(owner: "a")?.path)
    XCTAssertTrue(terminal.view.process.running)
    store.project = store.workspaceTabProject(owner: "a"); store.workspace.setProject(store.project)
    store.applyTaskSelection(store.library.tasks[0])
    XCTAssertEqual(store.workspaceTabs.count, 3)
    XCTAssertTrue(store.terminalSession(terminalID) === terminal)
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)
    XCTAssertEqual(store.library.drafts["a"], "A draft"); XCTAssertEqual(store.library.drafts["b"], "B draft")
  }

  func testSourcesTabRestoresOnlyForItsTask() throws {
    let store = try fixture()
    let saved = SavedWorkspaceTab(id: "sources:a", kind: .sources, placement: .detached)
    save([saved], store: store)
    let value = route(saved.id, store: store)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .ready("a"))
    XCTAssertEqual(store.prepareDetachedWorkspaceTab(value), value)
    XCTAssertTrue(store.workspaceTabs.contains(.sources(owner: "a")))
    XCTAssertEqual(store.selection, "b")

    let foreign = WorkspaceTabWindowRoute(tabID: saved.id, owner: "b", dataRoot: store.dataRoot)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(foreign), .close)
  }

  func testCloseBackgroundRestoredTabReturnsToOwnerAndCannotBeRestoredAgain() throws {
    let store = try fixture(), value = route("review:a", store: store)
    save([.init(id: value.tabID, kind: .review, placement: .detached)], store: store)
    XCTAssertNotNil(store.prepareDetachedWorkspaceTab(value))
    store.restoreDetachedWorkspaceTab(value.tabID)
    XCTAssertEqual(store.selection, "b")
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.tabs.first?.placement, .left)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .close)
    XCTAssertNil(store.prepareDetachedWorkspaceTab(value))
  }

  func testLegacyMigrationRejectsAmbiguousOwnersAndInvalidSavedTabs() throws {
    let store = try fixture(), id = "browser:\(UUID())"
    let legacy = WorkspaceTabWindowRoute(tabID: id)
    let saved = SavedWorkspaceTab(id: id, kind: .browser, placement: .detached)
    save([saved], store: store)
    XCTAssertEqual(store.prepareDetachedWorkspaceTab(legacy), route(id, store: store))
    save([saved], owner: "b", store: store)
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(legacy), .close)
    for entry in [SavedWorkspaceTab(id: "browser:invalid", kind: .browser, placement: .detached),
      .init(id: "review:wrong", kind: .review, placement: .detached),
      .init(id: "terminal:invalid", kind: .terminal, placement: .detached)] {
      save([entry], store: store)
      XCTAssertEqual(store.detachedWorkspaceTabRestoration(route(entry.id, store: store)), .close)
    }
  }

  func testCorruptLibraryRetryRetainsRouteAndRestoresOriginalOwner() async throws {
    let fixture = try fixture(), root = fixture.dataRoot
    let file = root.appendingPathComponent("workspace.json")
    try Data("invalid".utf8).write(to: file)
    let store = WorkspaceStore(dataRoot: root)
    let id = "browser:\(UUID())", value = route(id, store: store)
    await store.restore()
    guard case .failed = store.detachedWorkspaceTabRestoration(value) else {
      return XCTFail("Read failure must keep the restored window available for retry")
    }
    XCTAssertNil(store.prepareDetachedWorkspaceTab(value))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    var library = WorkspaceLibrary()
    library.lastWorkspace = ""
    library.tasks = [.init(id: "a", project: "", title: "A", runIDs: [])]
    library.workspaceTabLayouts["a"] = .init(
      tabs: [.init(id: id, kind: .browser, placement: .detached, address: "Restored address draft")],
      showingInspector: false, showingTerminal: false, showingTabs: true, side: .left, reviewScope: .unstaged)
    try library.save(to: file)
    await store.restore()
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .ready("a"))
    XCTAssertEqual(store.prepareDetachedWorkspaceTab(value), value)
    XCTAssertEqual(store.workspaceTabs.first?.owner, "a")
    XCTAssertEqual(store.workspace.browser.tabs.first?.address, "Restored address draft")
    await store.shutdown()
  }

  func testDeletedOwnerAndShutdownCannotCreateResources() throws {
    let store = try fixture(), value = route("review:a", store: store)
    save([.init(id: value.tabID, kind: .review, placement: .detached)], store: store)
    store.shuttingDown = true
    XCTAssertNil(store.prepareDetachedWorkspaceTab(value))
    store.shuttingDown = false
    store.library.tasks.removeAll { $0.id == "a" }
    XCTAssertEqual(store.detachedWorkspaceTabRestoration(value), .close)
    XCTAssertNil(store.prepareDetachedWorkspaceTab(value))
  }
}
