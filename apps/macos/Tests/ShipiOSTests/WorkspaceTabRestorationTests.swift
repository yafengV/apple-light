import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceTabRestorationTests: XCTestCase {
  private func fixture(project: Bool = true) throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tab-restore-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "a", project: project ? root.path : "", title: "A", runIDs: []),
      .init(id: "b", project: project ? root.path : "", title: "B", runIDs: [])]
    store.libraryLoaded = true
    store.scopeLoaded = true
    store.connected = project
    store.project = project ? root : nil
    store.workspace.setProject(store.project)
    store.selection = "a"
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  private func restarted(_ original: WorkspaceStore) throws -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: original.dataRoot)
    store.library = try WorkspaceLibrary.load(from: original.dataRoot.appendingPathComponent("workspace.json"))
    store.libraryLoaded = true; store.scopeLoaded = true
    store.project = original.project; store.connected = original.connected
    store.workspace.setProject(store.project)
    store.selection = original.selection
    addTeardownBlock { @MainActor in store.workspace.browser.shutdown(); store.workspace.terminals.shutdown() }
    store.restoreWorkspaceTabLayout()
    return store
  }

  func testMixedLayoutRoundTripKeepsIDsOrderPaneSelectionAndStartsFreshShell() throws {
    let original = try fixture()
    original.newBrowserTab()
    let browser = try XCTUnwrap(original.workspace.browser.selected)
    browser.address = "unfinished address"
    let browserID = try XCTUnwrap(original.activeWorkspaceTabID)
    original.newTerminalTab(in: .bottom)
    let terminalID = try XCTUnwrap(original.activeBottomWorkspaceTabID)
    let oldTerminal = try XCTUnwrap(original.terminalSession(try XCTUnwrap(original.activeBottomWorkspaceContentTab?.terminalID)))
    let oldPID = oldTerminal.view.process.shellPid
    original.openReviewTab()
    original.moveWorkspaceTab("review:a", to: .right)
    original.workspace.reviewScope = .staged
    original.activateWorkspaceTab(browserID)
    original.showingTerminal = false
    original.showingWorkspaceTabs = false
    original.workspaceContentPaneSide = .left
    original.saveLibrary()
    let restored = try restarted(original)
    XCTAssertEqual(restored.visibleWorkspaceContentTabs.map(\.id), original.visibleWorkspaceContentTabs.map(\.id))
    XCTAssertEqual(restored.activeWorkspaceTabID, browserID)
    XCTAssertEqual(restored.activeRightWorkspaceTabID, "review:a")
    XCTAssertEqual(restored.activeBottomWorkspaceTabID, terminalID)
    XCTAssertEqual(restored.workspaceTabPlacement(terminalID), .bottom)
    XCTAssertEqual(restored.workspace.reviewScope, .staged)
    XCTAssertEqual(restored.workspaceContentPaneSide, .left)
    XCTAssertFalse(restored.showingWorkspaceTabs)
    XCTAssertFalse(restored.showingTerminal)
    XCTAssertTrue(restored.showingInspector)
    XCTAssertEqual(restored.workspace.browser.selected?.address, "unfinished address")
    XCTAssertNil(restored.workspace.browser.selected?.view.url, "An address draft is not a navigation request")
    let newTerminal = try XCTUnwrap(restored.terminalSession(try XCTUnwrap(restored.activeBottomWorkspaceContentTab?.terminalID)))
    XCTAssertEqual(newTerminal.id, oldTerminal.id)
    XCTAssertFalse(newTerminal === oldTerminal)
    XCTAssertNotEqual(newTerminal.view.process.shellPid, oldPID)
    XCTAssertTrue(newTerminal.view.process.running)
  }

  func testLazyTaskRestoreDoesNotLoseUnvisitedCacheOrDuplicateLiveTabs() throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    let aID = try XCTUnwrap(original.activeWorkspaceTabID)
    original.workspace.browser.selected?.address = "A draft"
    original.applyTaskSelection(original.library.tasks[1])
    original.newBrowserTab()
    let bID = try XCTUnwrap(original.activeWorkspaceTabID)
    original.workspace.browser.selected?.address = "B draft"
    original.applyTaskSelection(original.library.tasks[0])
    original.saveLibrary()
    let restored = try restarted(original)
    let aBrowser = try XCTUnwrap(restored.workspace.browser.selected)
    XCTAssertEqual(restored.visibleWorkspaceContentTabs.map(\.id), [aID])
    restored.saveLibrary()
    XCTAssertEqual(restored.library.workspaceTabLayouts["b"]?.tabs.map(\.id), [bID])
    restored.applyTaskSelection(restored.library.tasks[1])
    XCTAssertEqual(restored.activeWorkspaceTabID, bID)
    XCTAssertEqual(restored.workspace.browser.selected?.address, "B draft")
    restored.restoreWorkspaceTabLayout()
    restored.applyTaskSelection(restored.library.tasks[0])
    XCTAssertTrue(restored.workspace.browser.selected === aBrowser)
    XCTAssertEqual(restored.workspaceTabs.count, 2)
  }

  func testPinnedReferenceReusesRestoredTab() async throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    let id = try XCTUnwrap(original.activeWorkspaceTabID)
    original.pinWorkspaceTab(id)
    let pinID = try XCTUnwrap(original.library.pinnedContentTabs.first?.id)
    original.saveLibrary()
    let restored = try restarted(original)
    let browser = restored.workspace.browser.selected
    await restored.openPinnedWorkspaceTab(pinID)
    XCTAssertEqual(restored.workspaceTabs.count, 1)
    XCTAssertTrue(restored.workspace.browser.selected === browser)
    XCTAssertEqual(restored.library.pinnedContentTabs.first?.sourceTabID, id)
  }

  func testSourcesTabRestoresAndPinnedOpenKeepsItsTask() async throws {
    let original = try fixture(project: false)
    XCTAssertTrue(original.openTaskSources())
    let tab = try XCTUnwrap(original.activeWorkspaceContentTab)
    XCTAssertEqual(tab, .sources(owner: "a"))
    original.moveWorkspaceTab(tab.id, to: .right)
    original.saveLibrary()

    let restored = try restarted(original)
    XCTAssertEqual(restored.activeRightWorkspaceContentTab, tab)
    XCTAssertEqual(restored.workspaceTabLayoutSnapshot.tabs.first?.kind, .sources)
    restored.pinWorkspaceTab(tab.id)
    let pin = try XCTUnwrap(restored.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.kind, .sources)
    restored.closeWorkspaceTab(tab.id)
    await restored.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(restored.activeWorkspaceContentTab, tab)
    XCTAssertNil(restored.materializeWorkspaceTab(
      SavedWorkspaceTab(id: tab.id, kind: .sources, placement: .left,
        address: nil, committedURL: nil), owner: "b"))
  }

  func testShutdownCapturesBeforeResourcesAreDestroyedAndClosedTabsStayClosed() async throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    let closed = try XCTUnwrap(original.activeWorkspaceTabID)
    original.newBrowserTab()
    let kept = try XCTUnwrap(original.activeWorkspaceTabID)
    original.closeWorkspaceTab(closed)
    await original.shutdown()
    let restored = try restarted(original)
    XCTAssertEqual(restored.workspaceTabs.map(\.id), [kept])
  }

  func testInvalidDuplicateAndImpossiblePlacementsAreIgnoredOrNormalized() throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    original.captureWorkspaceTabLayout()
    var layout = try XCTUnwrap(original.library.workspaceTabLayouts["a"])
    layout.tabs[0].placement = .bottom
    layout.tabs.append(layout.tabs[0])
    layout.tabs.append(.init(id: "broken", kind: .terminal, placement: .bottom))
    layout.active = "missing"; layout.bottom = "missing"
    original.library.workspaceTabLayouts["a"] = layout
    original.workspaceLayoutActiveOwner = nil
    try original.library.save(to: original.dataRoot.appendingPathComponent("workspace.json"))
    let restored = try restarted(original)
    XCTAssertEqual(restored.workspaceTabs.count, 1)
    XCTAssertEqual(restored.workspaceTabPlacement(try XCTUnwrap(restored.workspaceTabs.first?.id)), .left)
    XCTAssertNil(restored.activeWorkspaceTabID)
    XCTAssertNil(restored.activeBottomWorkspaceTabID)
  }

  func testMalformedLayoutCacheDoesNotBlockWorkspaceAndLegacyDefaultsEmpty() throws {
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.workspaceTabLayouts.isEmpty)
    let data = Data("{\"workspaceTabLayouts\": {\"a\": {\"unknown\":true}}, \"drafts\": {\"a\":\"Keep\"}}".utf8)
    let library = try JSONDecoder().decode(WorkspaceLibrary.self, from: data)
    XCTAssertTrue(library.workspaceTabLayouts.isEmpty)
    XCTAssertEqual(library.drafts["a"], "Keep")
  }

  func testDetachedTabKeepsStableRouteForWindowRestoration() throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    let id = try XCTUnwrap(original.activeWorkspaceTabID)
    original.moveWorkspaceTab(id, to: .detached)
    original.saveLibrary()
    let restored = try restarted(original)
    XCTAssertEqual(restored.workspaceTabPlacement(id), .detached)
    XCTAssertEqual(restored.restoredDetachedWorkspaceTabIDs, [id])
    restored.restoredDetachedWorkspaceTabIDs = []
    restored.restoreWorkspaceTabLayout()
    XCTAssertTrue(restored.restoredDetachedWorkspaceTabIDs.isEmpty)
  }

  func testLoadingCannotOverwriteUnrestoredLayoutAndDeletedTasksPruneCache() throws {
    let original = try fixture()
    original.newBrowserTab()
    original.saveLibrary()
    let saved = original.library.workspaceTabLayouts["a"]
    let cold = WorkspaceStore(dataRoot: original.dataRoot)
    cold.library = original.library
    cold.libraryLoaded = true
    cold.selection = "a"
    cold.saveLibrary()
    cold.restoreWorkspaceTabLayout()
    XCTAssertEqual(cold.library.workspaceTabLayouts["a"], saved)
    XCTAssertTrue(cold.workspaceTabs.isEmpty)
    cold.library.tasks[0].archived = true
    cold.library.deleteArchivedTasks(["a"])
    XCTAssertNil(cold.library.workspaceTabLayouts["a"])
  }
  func testRealProjectlessStartupRestoresCachedLayoutWithoutLoadingLoop() async throws {
    let original = try fixture(project: false)
    original.newBrowserTab()
    let id = try XCTUnwrap(original.activeWorkspaceTabID)
    original.workspace.browser.selected?.address = "unsent localhost draft"
    original.library.lastWorkspace = ""
    original.library.projectSelections[""] = "a"
    original.saveLibrary()
    let cold = WorkspaceStore(dataRoot: original.dataRoot)
    defer { cold.workspace.browser.shutdown() }
    await cold.restore()
    XCTAssertTrue(cold.scopeLoaded)
    XCTAssertFalse(cold.restoringLibrary)
    XCTAssertNil(cold.libraryReadError)
    XCTAssertEqual(cold.selectedTask?.id, "a")
    XCTAssertEqual(cold.activeWorkspaceTabID, id)
    XCTAssertEqual(cold.workspace.browser.selected?.address, "unsent localhost draft")
    XCTAssertNil(cold.workspace.browser.selected?.view.url)
  }

  func testLeavingProjectCapturesPanelsBeforeScopeReset() async throws {
    let original = try fixture()
    original.newBrowserTab()
    let id = try XCTUnwrap(original.activeWorkspaceTabID)
    original.moveWorkspaceTab(id, to: .right)
    original.newTerminalTab(in: .bottom)
    await original.openProjectless()
    let layout = try XCTUnwrap(original.library.workspaceTabLayouts["a"])
    XCTAssertTrue(layout.showingInspector)
    XCTAssertTrue(layout.showingTerminal)
    XCTAssertEqual(layout.right, id)
    XCTAssertEqual(layout.tabs.count, 2)
  }

}
