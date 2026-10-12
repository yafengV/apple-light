import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class BrowserFocusOwnershipTests: XCTestCase {
  private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  func testQueuedAddressFocusCannotReselectBrowserAfterReturningToChat() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: [])]
    store.applyTaskSelection(store.library.tasks[0])
    store.newBrowserTab(in: .right)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    page.setCustomTitle("Reopened page")
    let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 550),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let content = NSView(frame: window.contentLayoutRect)
    let panel = NSHostingView(rootView: BrowserPanel(store: store,
      session: store.workspace.browser, showsTabStrip: false, tabID: page.id))
    panel.frame = .init(x: 0, y: 0, width: 700, height: 480)
    content.addSubview(panel)
    let chatTarget = NSButton(frame: .init(x: 0, y: 490, width: 100, height: 30))
    content.addSubview(chatTarget); window.contentView = content
    panel.layoutSubtreeIfNeeded()
    XCTAssertNotNil(store.workspace.browser.addressField)
    XCTAssertTrue(window.makeFirstResponder(chatTarget))
    // Navigation wins before the queued address request and the outgoing view's
    // dismantling. The right selection remains saved, so visibility alone is stale.
    store.activateChatTab()
    XCTAssertTrue(store.browserVisible)
    XCTAssertNil(store.focusedWorkspaceContentTab)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(window.firstResponder === chatTarget)
    XCTAssertNil(store.focusedWorkspaceContentTab, "A departing address field must not navigate back to its browser")
    XCTAssertFalse(page.editingAddress)
    XCTAssertTrue(store.workspace.browser.selected === page)
  }
}
