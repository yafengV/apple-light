import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class DetachedWindowCommandTests: XCTestCase {
  private final class TestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }
  private func fixture() throws -> (WorkspaceStore, BrowserTab, BrowserTab) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-command-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.selection = "a"; store.restoreWorkspaceTabLayout()
    store.newBrowserTab(in: .detached)
    let a = try XCTUnwrap(store.workspace.browser.selected)
    store.applyTaskSelection(store.library.tasks[1])
    store.newBrowserTab()
    let b = try XCTUnwrap(store.workspace.browser.selected)
    store.library.drafts["a"] = "A draft"; store.library.drafts["b"] = "B draft"
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, a, b)
  }
  private func tabID(_ page: BrowserTab) -> String { "browser:\(page.id)" }

  func testAddressFocusAndCloseWindowDoNotTouchSelectedMainBrowser() throws {
    let (store, a, b) = try fixture()
    var closed = 0
    let context = store.detachedWindowCommands(tabID(a), close: { closed += 1 })
    let layout = store.workspaceTabLayoutSnapshot
    XCTAssertEqual(context.closeTitle, "关闭标签页窗口")
    XCTAssertNil(context.command(for: ShortcutBinding("⌘←"), shortcuts: store.shortcuts),
      "Navigation editing keys require native browser focus")
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘L"), shortcuts: store.shortcuts), "browser-address")
    XCTAssertTrue(context.execute("browser-address"))
    XCTAssertEqual(store.workspace.browser.addressFocusTarget, a.id)
    XCTAssertEqual(store.workspace.browser.selection, b.id)
    XCTAssertTrue(context.execute("tab-close"))
    XCTAssertEqual(closed, 1)
    XCTAssertFalse(a.closed); XCTAssertFalse(b.closed)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout)
    XCTAssertEqual(store.selection, "b")
    for command in ["send", "stop", "archive", "pin", "rename", "tab-close-others", "focus-chat-1", "previous-task"] {
      XCTAssertFalse(context.execute(command), command)
    }
    XCTAssertEqual(store.library.drafts["a"], "A draft"); XCTAssertEqual(store.library.drafts["b"], "B draft")
  }

  func testBrowserCloseClosesOnlyOwnedPageAndStaleCommandsCannotAct() throws {
    let (store, a, b) = try fixture()
    var closed = 0
    let context = store.detachedWindowCommands(tabID(a), close: { closed += 1 })
    XCTAssertTrue(context.execute("browser-close"))
    XCTAssertTrue(a.closed); XCTAssertFalse(b.closed)
    XCTAssertEqual(closed, 1)
    _ = context.execute("tab-close")
    _ = context.execute("browser-address")
    XCTAssertEqual(closed, 1)
    XCTAssertEqual(store.workspace.browser.selection, b.id)
    XCTAssertTrue(store.detachedWindowCommands(tabID(a), close: {}).enabled.isEmpty)
  }

  func testReturnedTabAndShutdownRejectOldWindowCommands() throws {
    let (store, a, b) = try fixture()
    var closed = false
    let context = store.detachedWindowCommands(tabID(a), close: { closed = true })
    store.restoreDetachedWorkspaceTab(tabID(a))
    _ = context.execute("browser-close")
    XCTAssertFalse(closed); XCTAssertFalse(a.closed)
    store.workspaceTabPlacements[tabID(a)] = .detached
    store.shuttingDown = true
    _ = context.execute("browser-close")
    XCTAssertFalse(closed); XCTAssertFalse(a.closed); XCTAssertFalse(b.closed)
  }

  func testDetachedNonBrowserWindowOwnsCloseAndDoesNotExposeMainBrowserActions() throws {
    let (store, _, _) = try fixture()
    let review = WorkspaceContentTab.review(owner: "a")
    store.workspaceTabs.append(review); store.workspaceTabPlacements[review.id] = .detached
    let context = store.detachedWindowCommands(review.id, close: {})
    XCTAssertEqual(context.enabled, ["tab-close"])
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘W"), shortcuts: store.shortcuts), "tab-close")
    try store.shortcuts.set(ShortcutBinding("⌃⌥L"), for: "browser-address")
    XCTAssertEqual(context.command(for: ShortcutBinding("⌃⌥L"), shortcuts: store.shortcuts), "browser-address")
    XCTAssertFalse(context.execute("browser-address"))
  }

  func testMountedDetachedBrowserAddressFocusDoesNotSelectMainPage() async throws {
    let (store, a, b) = try fixture()
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 850, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceTabWindowView(store: store, tabID: tabID(a)))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    func address(_ view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.accessibilityLabel() == "浏览器地址" { return field }
      return view.subviews.lazy.compactMap { address($0) }.first
    }
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if address(host) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let field = try XCTUnwrap(address(host))
    let context = store.detachedWindowCommands(tabID(a), close: {})
    XCTAssertTrue(context.execute("browser-address"))
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      if field.currentEditor() != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(field.currentEditor(), "Detached address must focus even with the other main browser selected")
    XCTAssertTrue(window.firstResponder === field.currentEditor())
    XCTAssertEqual(store.workspace.browser.selection, b.id)
    XCTAssertEqual(store.selection, "b")
    XCTAssertTrue(store.workspace.browser.hasEditableFocus(tabID: a.id, in: window))
    XCTAssertTrue(window.makeFirstResponder(a.view))
    a.setPageEditableFocus(frame: "editor", editable: true)
    XCTAssertTrue(store.workspace.browser.hasEditableFocus(tabID: a.id, in: window))
    a.setPageEditableFocus(frame: "editor", editable: false)
    XCTAssertFalse(store.workspace.browser.hasEditableFocus(tabID: a.id, in: window))
  }

  func testElementReferencesRemainInExplicitTaskAndDraftOwner() throws {
    let (store, _, _) = try fixture()
    let reference = BrowserElementReference(url: "https://example.invalid", pageTitle: "A", selector: "h1",
      tag: "h1", text: "Title", accessibilityLabel: "", role: "heading", rect: .init(x: 0, y: 0, width: 100, height: 20))
    store.addBrowserElementToDraft(reference, taskID: "a")
    store.addBrowserComment(reference, body: "A comment", taskID: "a")
    XCTAssertTrue(store.library.drafts["a"]?.contains(reference.promptContext) == true)
    XCTAssertEqual(store.library.drafts["b"], "B draft")
    XCTAssertEqual(store.browserComments(taskID: "a").count, 1)
    XCTAssertTrue(store.browserComments(taskID: "b").isEmpty)
    store.addBrowserElementToDraft(reference, taskID: "new:none")
    XCTAssertEqual(store.library.drafts["new:none"], reference.promptContext)
    store.addBrowserElementToDraft(reference, taskID: "deleted")
    XCTAssertNil(store.library.drafts["deleted"])
  }
}
