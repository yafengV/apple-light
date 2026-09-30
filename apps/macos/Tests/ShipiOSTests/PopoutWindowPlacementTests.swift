import AppKit
import XCTest
@testable import ShipiOS

final class PopoutWindowPlacementTests: XCTestCase {
  func testInitialHomeSharesThreadBottomEdge() {
    let display = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let thread = PopoutWindowPlacement.initialThread(in: display)
    let home = PopoutWindowPlacement.initialHome(in: display)
    XCTAssertEqual(thread, NSRect(x: 485, y: 208, width: 470, height: 640))
    XCTAssertEqual(home, NSRect(x: 485, y: 208, width: 470, height: 290))
  }

  func testSwitchingSurfacesPreservesBottomEdgeAndThreadWidth() {
    let display = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let movedThread = NSRect(x: 300, y: 120, width: 700, height: 500)
    let home = PopoutWindowPlacement.home(alignedTo: movedThread,
      in: display, height: 290)
    XCTAssertEqual(home, NSRect(x: 300, y: 120, width: 700, height: 290))
    let movedHome = NSRect(x: 160, y: 180, width: 470, height: 290)
    let thread = PopoutWindowPlacement.thread(alignedTo: movedHome,
      in: display, size: NSSize(width: 700, height: 500))
    XCTAssertEqual(thread, NSRect(x: 45, y: 180, width: 700, height: 500))
  }

  func testInitialFramesClampToSmallDisplay() {
    let display = NSRect(x: 100, y: 50, width: 430, height: 520)
    let thread = PopoutWindowPlacement.initialThread(in: display)
    let home = PopoutWindowPlacement.initialHome(in: display)
    XCTAssertEqual(thread, NSRect(x: 100, y: 50, width: 430, height: 520))
    XCTAssertEqual(home, NSRect(x: 100, y: 50, width: 430, height: 290))
  }
}
