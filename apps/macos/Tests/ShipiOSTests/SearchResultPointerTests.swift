import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class SearchResultPointerTests: XCTestCase {
  private final class TestWindow: NSWindow {
    var activeForTest = true
    override var isKeyWindow: Bool { activeForTest }
  }

  func testMountingAndTrackingUpdatesDoNotSelectUntilVisiblePointerMovement() throws {
    _ = NSApplication.shared
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let row = SearchResultPointerBridge.PointerView(frame: .init(x: 20, y: 30, width: 150, height: 40))
    window.contentView?.addSubview(row)
    var selections = 0
    row.enabled = true
    row.select = { selections += 1 }
    row.updateTrackingAreas()
    row.updateTrackingAreas()
    XCTAssertEqual(row.trackingAreas.count, 1)
    XCTAssertEqual(selections, 0)
    XCTAssertNil(row.hitTest(.init(x: 30, y: 40)), "The bridge must leave clicks to the row button")
    row.receiveMovement(in: window, locationInWindow: .init(x: 30, y: 40))
    XCTAssertEqual(selections, 1)
    row.receiveMovement(in: window, locationInWindow: .init(x: 190, y: 40))
    XCTAssertEqual(selections, 1)
    row.enabled = false
    row.receiveMovement(in: window, locationInWindow: .init(x: 30, y: 40))
    XCTAssertEqual(selections, 1)
    row.enabled = true
    window.activeForTest = false
    row.receiveMovement(in: window, locationInWindow: .init(x: 30, y: 40))
    XCTAssertEqual(selections, 1)
    window.activeForTest = true
    row.isHidden = true
    row.receiveMovement(in: window, locationInWindow: .init(x: 30, y: 40))
    XCTAssertEqual(selections, 1)
  }

  func testOtherWindowEventsClippedRowsAndRemovedCallbacksCannotChangeSelection() throws {
    _ = NSApplication.shared
    let windows = (0..<2).map { _ in TestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false) }
    windows.forEach { $0.isReleasedWhenClosed = false }
    defer { windows.forEach { $0.close() } }
    let container = NSView(frame: .init(x: 10, y: 10, width: 100, height: 20))
    container.clipsToBounds = true
    let row = SearchResultPointerBridge.PointerView(frame: .init(x: 0, y: 0, width: 100, height: 60))
    windows[0].contentView?.addSubview(container)
    container.addSubview(row)
    row.enabled = true
    var selections = 0
    row.select = { selections += 1 }
    row.receiveMovement(in: windows[1], locationInWindow: .init(x: 20, y: 20))
    row.receiveMovement(in: windows[0], locationInWindow: .init(x: 20, y: 50))
    XCTAssertEqual(selections, 0)
    row.receiveMovement(in: windows[0], locationInWindow: .init(x: 20, y: 20))
    XCTAssertEqual(selections, 1)
    SearchResultPointerBridge.dismantleNSView(row, coordinator: ())
    row.receiveMovement(in: windows[0], locationInWindow: .init(x: 20, y: 20))
    XCTAssertEqual(selections, 1)
  }

}
