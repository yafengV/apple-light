import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class BrowserPanelLifecycleTests: XCTestCase {
  func testMountingBackgroundPaneDoesNotSelectOrFocusItsBrowser() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore()
    let session = BrowserSession()
    defer { session.shutdown() }
    let first = session.newTab(activate: false)
    let second = session.newTab(activate: false)
    var selections: [UUID] = []
    session.onTabSelected = { selections.append($0) }

    for current in [nil, second.id] {
      if let current { session.select(current, focus: false) }
      selections = []
      let addressRequest = session.addressFocus, contentRequest = session.contentFocus
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: BrowserPanel(store: store, session: session,
        showsTabStrip: false, tabID: first.id))
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(session.selection, current, "Mounting a pane must not activate a background tab")
      XCTAssertTrue(selections.isEmpty, "Only explicit user activation should publish selection")
      XCTAssertEqual(session.addressFocus, addressRequest)
      XCTAssertEqual(session.contentFocus, contentRequest)
      window.close()
    }
  }

  func testAddressSuggestionsDoNotResizeTheWebPage() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore()
    let session = BrowserSession()
    defer { session.shutdown() }
    let tab = session.newTab()
    store.library.browserHistory = [BrowserHistoryEntry(url: "https://swift.org", title: "Swift Home")]
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: BrowserPanel(store: store, session: session, showsTabStrip: false))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let initialHeight = tab.view.frame.height
    XCTAssertGreaterThan(initialHeight, 0)

    let field = try XCTUnwrap(session.addressField)
    field.stringValue = "swift"
    field.delegate?.controlTextDidBeginEditing?(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(tab.view.frame.height, initialHeight, accuracy: 1,
      "Opening address suggestions must overlay the page instead of moving it")
    window.close()
  }
}
