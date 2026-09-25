import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowTabRestorationTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-layout-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "a", project: root.path, title: "A", runIDs: []),
      .init(id: "b", project: root.path, title: "B", runIDs: [])]
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return store
  }
  private func window(_ store: WorkspaceStore, id: String = "window", task: String = "a") -> TaskWindowResources {
    let resources = TaskWindowResources()
    resources.prepare(task, store: store, windowID: id)
    addTeardownBlock { @MainActor in resources.shutdown() }
    return resources
  }
  private func cold(_ store: WorkspaceStore) throws -> WorkspaceStore {
    let cold = WorkspaceStore(dataRoot: store.dataRoot)
    cold.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    cold.libraryLoaded = true
    return cold
  }

  func testMixedLayoutKeepsIDsSelectionSizesAndCreatesFreshShellWithoutFocus() throws {
    let store = try fixture(), source = window(store)
    let tabs = try XCTUnwrap(source.tasks["a"])
    tabs.newBrowser()
    let page = try XCTUnwrap(tabs.browser.session.selected)
    page.address = "unfinished address"
    let pageID = try XCTUnwrap(tabs.focusedID)
    tabs.openReview(in: .right, defaultScope: .staged)
    tabs.newTerminal()
    let terminal = try XCTUnwrap(tabs.panels.terminal)
    tabs.activate(pageID)
    tabs.showingBottom = false
    tabs.showingTabs = false
    tabs.primarySide = .right
    tabs.panels.resizeInspector(to: 530)
    tabs.panels.resizeTerminal(to: 270)
    store.saveLibrary()
    let loaded = try cold(store), restored = window(loaded)
    let result = try XCTUnwrap(restored.tasks["a"])
    XCTAssertEqual(result.layoutSnapshot, tabs.layoutSnapshot)
    XCTAssertEqual(result.browser.session.selected?.id, page.id)
    XCTAssertEqual(result.browser.session.selected?.address, "unfinished address")
    XCTAssertNil(result.browser.session.selected?.view.url)
    XCTAssertNil(result.browser.session.addressFocusTarget)
    XCTAssertNil(result.browser.session.contentFocusTarget)
    XCTAssertNil(result.panels.terminalFocus)
    let replacement = try XCTUnwrap(result.panels.terminal)
    XCTAssertEqual(replacement.id, terminal.id)
    XCTAssertFalse(replacement === terminal)
    XCTAssertNotEqual(replacement.view.process.shellPid, terminal.view.process.shellPid)
    XCTAssertTrue(replacement.view.process.running)
    restored.prepare("a", store: loaded, windowID: "window")
    XCTAssertEqual(result.tabs.count, 3)
    XCTAssertTrue(result.panels.terminal === replacement)
  }

  func testDifferentWindowsAndMainWorkspaceDoNotOverwriteSameTask() throws {
    let store = try fixture(), first = window(store, id: "first"), second = window(store, id: "second")
    let a = try XCTUnwrap(first.tasks["a"]), b = try XCTUnwrap(second.tasks["a"])
    a.newBrowser(); a.browser.session.selected?.address = "first draft"
    b.newBrowser(in: .right); b.browser.session.selected?.address = "second draft"
    store.scopeLoaded = true
    store.selection = "b"
    store.restoreWorkspaceTabLayout()
    store.newBrowserTab()
    store.workspace.browser.selected?.address = "main draft"
    defer { store.workspace.browser.shutdown() }
    store.saveLibrary()
    let loaded = try cold(store)
    let restoredA = window(loaded, id: "first"), restoredB = window(loaded, id: "second")
    XCTAssertEqual(restoredA.tasks["a"]?.browser.session.selected?.address, "first draft")
    XCTAssertEqual(restoredB.tasks["a"]?.browser.session.selected?.address, "second draft")
    XCTAssertEqual(loaded.library.workspaceTabLayouts["b"]?.tabs.first?.address, "main draft")
    XCTAssertNotEqual(restoredA.tasks["a"]?.tabs.first?.id, restoredB.tasks["a"]?.tabs.first?.id)
  }

  func testUnvisitedTaskCacheSurvivesSaveAndNavigationDoesNotDuplicate() throws {
    let store = try fixture(), source = window(store)
    source.tasks["a"]?.newBrowser()
    source.tasks["a"]?.browser.session.selected?.address = "A"
    source.prepare("b", store: store)
    source.tasks["b"]?.newBrowser()
    source.tasks["b"]?.browser.session.selected?.address = "B"
    store.saveLibrary()
    let loaded = try cold(store), restored = window(loaded)
    let originalA = restored.tasks["a"]?.browser.session.selected
    loaded.saveLibrary()
    XCTAssertEqual(loaded.library.taskWindowTabLayouts["window"]?["b"]?.content.tabs.first?.address, "B")
    restored.prepare("b", store: loaded)
    restored.prepare("a", store: loaded)
    XCTAssertTrue(restored.tasks["a"]?.browser.session.selected === originalA)
    XCTAssertEqual(restored.tasks["b"]?.browser.session.selected?.address, "B")
    XCTAssertEqual(restored.tasks["a"]?.tabs.count, 1)
  }

  func testShutdownSavesBeforeCleanupAndPinReferencesRestoredWindow() async throws {
    let store = try fixture(), source = window(store)
    let tabs = try XCTUnwrap(source.tasks["a"])
    tabs.newBrowser()
    let page = try XCTUnwrap(tabs.browser.session.selected)
    page.address = "keep"
    source.pin(try XCTUnwrap(tabs.focusedID), taskID: "a")
    tabs.newTerminal()
    let terminal = try XCTUnwrap(tabs.panels.terminal)
    await store.shutdown()
    XCTAssertTrue(source.tasks.isEmpty)
    XCTAssertFalse(terminal.view.process.running)
    let loaded = try cold(store), restored = window(loaded)
    let pin = try XCTUnwrap(loaded.library.pinnedContentTabs.first)
    XCTAssertTrue(restored.contains(pin))
    XCTAssertEqual(restored.tasks["a"]?.browser.session.tabs.first?.id, page.id)
    XCTAssertEqual(restored.tasks["a"]?.tabs.count, 2)
  }

  func testClosedTabsRemainClosedAndDeletedTasksPruneEveryWindow() throws {
    let store = try fixture(), source = window(store), other = window(store, id: "other")
    let tabs = try XCTUnwrap(source.tasks["a"])
    tabs.newBrowser()
    tabs.close(try XCTUnwrap(tabs.focusedID))
    other.tasks["a"]?.newBrowser()
    source.shutdown()
    let loaded = try cold(store), restored = window(loaded)
    XCTAssertTrue(try XCTUnwrap(restored.tasks["a"]).tabs.isEmpty)
    loaded.library.tasks[0].archived = true
    loaded.library.deleteArchivedTasks(["a"])
    loaded.saveLibrary()
    XCTAssertTrue(loaded.library.taskWindowTabLayouts.values.allSatisfy { $0["a"] == nil })
  }

  func testChangedProjectDoesNotRestartShellOrReviewInDifferentDirectory() throws {
    let store = try fixture(), source = window(store)
    let tabs = try XCTUnwrap(source.tasks["a"])
    tabs.newBrowser(); tabs.browser.session.selected?.address = "keep browser"
    tabs.openReview(in: .right, defaultScope: .staged)
    tabs.newTerminal()
    tabs.panels.showingFiles = true
    store.saveLibrary()
    let loaded = try cold(store)
    loaded.library.tasks[0].project = ""
    let restored = window(loaded), result = try XCTUnwrap(restored.tasks["a"])
    XCTAssertEqual(result.tabs.count, 1)
    XCTAssertEqual(result.browser.session.tabs.first?.address, "keep browser")
    XCTAssertTrue(result.panels.terminals.isEmpty)
    XCTAssertFalse(result.showingBottom)
    XCTAssertFalse(result.showingRight)
    XCTAssertFalse(result.panels.showingFiles)
  }

  func testMalformedOptionalCacheDoesNotBlockTasksAndRoutesKeepWindowIdentity() throws {
    let legacy = try JSONDecoder().decode(TaskWindowRoute.self, from: Data(#"{"taskID":"a"}"#.utf8))
    XCTAssertEqual(legacy.id, "a")
    XCTAssertNil(legacy.windowID)
    let a = TaskWindowRoute(taskID: "a", dataRoot: .temporaryDirectory)
    let b = TaskWindowRoute(taskID: "b", dataRoot: .temporaryDirectory, windowID: a.id)
    XCTAssertEqual(a.id, b.id)
    XCTAssertNotEqual(b.id, TaskWindowRoute(taskID: "b", dataRoot: .temporaryDirectory).id)
    XCTAssertEqual(try JSONDecoder().decode(TaskWindowRoute.self, from: JSONEncoder().encode(b)), b)
    let library = try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data(#"{"taskWindowTabLayouts":{"window":false},"drafts":{"a":"keep"}}"#.utf8))
    XCTAssertTrue(library.taskWindowTabLayouts.isEmpty)
    XCTAssertEqual(library.drafts["a"], "keep")
  }

  func testPinRevealsUnvisitedRestoredTaskInItsOriginalWindow() throws {
    let store = try fixture(), source = window(store)
    source.tasks["a"]?.newBrowser()
    let id = try XCTUnwrap(source.tasks["a"]?.focusedID)
    source.pin(id, taskID: "a")
    source.prepare("b", store: store)
    store.saveLibrary()
    let loaded = try cold(store), restored = window(loaded, task: "b")
    let native = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 150),
      styleMask: [.titled], backing: .buffered, defer: false)
    native.isReleasedWhenClosed = false
    defer { native.close() }
    restored.window = native
    var destination: String?
    restored.navigate = { destination = $0 }
    let pin = try XCTUnwrap(loaded.library.pinnedContentTabs.first)
    XCTAssertNil(restored.tasks["a"])
    XCTAssertTrue(restored.reveal(pin))
    XCTAssertEqual(destination, "a")
    XCTAssertEqual(restored.tasks["a"]?.focusedID, id)
    XCTAssertTrue(loaded.workspaceTabs.isEmpty)
    XCTAssertTrue(restored.reveal(pin))
    XCTAssertEqual(restored.tasks["a"]?.tabs.count, 1)
  }

  func testInvalidSavedTabsAndHiddenSelectionCannotReopenPanels() throws {
    let store = try fixture(), source = window(store)
    let tabs = try XCTUnwrap(source.tasks["a"])
    tabs.newBrowser(in: .right)
    var saved = tabs.layoutSnapshot
    saved.content.showingInspector = false
    saved.content.tabs.append(saved.content.tabs[0])
    saved.content.tabs.append(.init(id: "broken", kind: .terminal, placement: .bottom))
    source.shutdown()
    store.library.taskWindowTabLayouts["window"] = ["a": saved]
    store.saveLibrary()
    let loaded = try cold(store), restored = window(loaded)
    let result = try XCTUnwrap(restored.tasks["a"])
    XCTAssertEqual(result.tabs.count, 1)
    XCTAssertFalse(result.showingRight)
    XCTAssertNil(result.focusedID, "Window appearance must not activate a hidden pane")
    XCTAssertTrue(result.panels.terminals.isEmpty)
  }
}
