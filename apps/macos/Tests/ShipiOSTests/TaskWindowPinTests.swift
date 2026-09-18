import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowPinTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, TaskWindowResources, TaskWindowTabs) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-window-pins-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.project = root
    store.library.tasks = [
      .init(id: "popup", project: root.path, title: "Popup", runIDs: []),
      .init(id: "main", project: root.path, title: "Main", runIDs: [])]
    store.selection = "main"
    store.library.drafts["main"] = "Keep main draft"
    store.libraryLoaded = true
    let resources = TaskWindowResources()
    resources.prepare("popup", store: store)
    return (store, resources, try XCTUnwrap(resources.tasks["popup"]))
  }

  func testLivePinRevealsExactWindowAndBrowserWithoutChangingMainTask() async throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    resources.window = window
    var navigated: [String] = []
    resources.navigate = { navigated.append($0) }
    tabs.newBrowser()
    let source = try XCTUnwrap(tabs.focused), browser = try XCTUnwrap(tabs.browser.session.selected)
    browser.address = "http://127.0.0.1:1234/draft"
    resources.pin(source.id, taskID: "popup")
    resources.pin(source.id, taskID: "popup")
    XCTAssertEqual(store.library.pinnedContentTabs.count, 1)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.sourceWindowID, resources.id)
    XCTAssertTrue(store.pinnedWorkspaceTabIsLive(pin))
    XCTAssertEqual(store.library.sidebarItems(in: SidebarLayout.pinned), [.contentTab(pin.id)])
    tabs.activate(nil)
    await store.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(navigated, ["popup"])
    XCTAssertEqual(tabs.focusedID, source.id)
    XCTAssertTrue(tabs.browser.session.selected === browser)
    XCTAssertTrue(store.workspace.browser.tabs.isEmpty)
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["main"], "Keep main draft")
    XCTAssertTrue(window.isVisible)
  }

  func testWindowScopedReviewPinsDoNotCollideWithMainOrAnotherWindow() throws {
    let (store, resources, tabs) = try fixture()
    let other = TaskWindowResources()
    defer { resources.shutdown(); other.shutdown() }
    other.prepare("popup", store: store)
    let second = try XCTUnwrap(other.tasks["popup"])
    store.selection = "popup"
    store.openReviewTab()
    store.pinWorkspaceTab("review:popup")
    tabs.openReview(defaultScope: .unstaged)
    second.openReview(defaultScope: .staged)
    resources.pin("review:popup", taskID: "popup")
    other.pin("review:popup", taskID: "popup")
    XCTAssertEqual(store.library.pinnedContentTabs.count, 3)
    store.unpinWorkspaceTab("review:popup", windowID: resources.id)
    XCTAssertFalse(store.isWorkspaceTabPinned("review:popup", windowID: resources.id))
    XCTAssertTrue(store.isWorkspaceTabPinned("review:popup", windowID: other.id))
    XCTAssertTrue(store.isWorkspaceTabPinned("review:popup"))
    store.unpinWorkspaceTab("review:popup")
    XCTAssertEqual(store.library.pinnedContentTabs.map(\.sourceWindowID), [other.id])
  }

  func testClosingSourceCapturesAddressAndRestoresOneDurableReferenceInMain() async throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown(); store.workspace.browser.shutdown() }
    tabs.newBrowser()
    let source = try XCTUnwrap(tabs.focused), browser = try XCTUnwrap(tabs.browser.session.selected)
    resources.pin(source.id, taskID: "popup")
    browser.address = "this is an unfinished address"
    tabs.close(source.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.restoreURL, browser.address)
    XCTAssertFalse(store.pinnedWorkspaceTabIsLive(pin))
    await store.openPinnedWorkspaceTab(pin.id)
    let restored = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(restored.id, pin.id)
    XCTAssertNil(restored.sourceWindowID)
    XCTAssertNotEqual(restored.sourceTabID, pin.sourceTabID)
    XCTAssertTrue(store.pinnedWorkspaceTabIsLive(restored))
    XCTAssertEqual(store.workspace.browser.selected?.address, pin.restoreURL)
    XCTAssertEqual(store.library.pinnedContentTabs.count, 1)
  }

  func testTerminalPinFollowsRestartAndClosingWindowStopsAllLiveResources() throws {
    let (store, resources, tabs) = try fixture()
    tabs.newTerminal()
    let source = try XCTUnwrap(tabs.focused), session = try XCTUnwrap(tabs.panels.terminal)
    resources.pin(source.id, taskID: "popup")
    let pinID = try XCTUnwrap(store.library.pinnedContentTabs.first?.id)
    tabs.restartTerminal(session.id)
    let replacement = try XCTUnwrap(tabs.panels.terminal)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.id, pinID)
    XCTAssertNotEqual(pin.sourceTabID, source.id)
    XCTAssertEqual(pin.sourceTabID, tabs.focusedID)
    XCTAssertTrue(store.pinnedWorkspaceTabIsLive(pin))
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.pinnedContentTabs.first?.sourceTabID, pin.sourceTabID)
    resources.shutdown()
    XCTAssertFalse(store.pinnedWorkspaceTabIsLive(pin))
    XCTAssertTrue(resources.tasks.isEmpty)
    XCTAssertFalse(replacement.view.process.running)
  }

  func testPinEncodingSupportsOldRecordsAndRegistryDoesNotRetainClosedWindow() throws {
    let old = Data(#"{"id":"pin","sourceTabID":"review:task","owner":"task","kind":"review","title":"Review"}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(PinnedWorkspaceTab.self, from: old).sourceWindowID)
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    resources.pin(try XCTUnwrap(tabs.focusedID), taskID: "popup")
    let decoded = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    XCTAssertEqual(decoded.pinnedContentTabs, store.library.pinnedContentTabs)
    var transient: TaskWindowResources? = TaskWindowResources()
    transient?.prepare("main", store: store)
    weak var weakResources = transient
    transient?.shutdown()
    transient = nil
    XCTAssertNil(weakResources)
    XCTAssertEqual(store.taskWindowResources.allObjects.count, 1)
  }

  func testAppShutdownCapturesLatestPinBeforeBrowserCleanup() async throws {
    let (store, resources, tabs) = try fixture()
    tabs.newBrowser()
    let browser = try XCTUnwrap(tabs.browser.session.selected)
    resources.pin(try XCTUnwrap(tabs.focusedID), taskID: "popup")
    browser.address = "latest unsubmitted address"
    await store.shutdown()
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.pinnedContentTabs.first?.restoreURL, "latest unsubmitted address")
    XCTAssertTrue(resources.tasks.isEmpty)
    XCTAssertTrue(browser.closed)
    XCTAssertNil(resources.navigate)
  }

  func testOldAttachmentCannotClearReplacementWindowRegistration() {
    let resources = TaskWindowResources()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let old = NSView(), replacement = NSView()
    resources.attach(window: window, from: old)
    resources.attach(window: window, from: replacement)
    resources.attach(window: nil, from: old)
    XCTAssertTrue(resources.window === window)
    resources.attach(window: nil, from: replacement)
    XCTAssertNil(resources.window)
  }
}
