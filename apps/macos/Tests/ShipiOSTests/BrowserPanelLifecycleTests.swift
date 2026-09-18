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
}
