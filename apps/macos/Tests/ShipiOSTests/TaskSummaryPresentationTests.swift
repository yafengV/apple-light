import XCTest
@testable import ShipiOS

final class TaskSummaryPresentationTests: XCTestCase {
  func testLayoutBoundariesFollowTheConversationContentWidth() {
    var presentation = TaskSummaryPresentation()
    presentation.resize(to: 1_095)
    XCTAssertEqual(presentation.mode, .overlay)
    presentation.resize(to: 1_096)
    XCTAssertEqual(presentation.mode, .shift)
    presentation.resize(to: 1_535)
    XCTAssertEqual(presentation.mode, .shift)
    presentation.resize(to: 1_536)
    XCTAssertEqual(presentation.mode, .gutter)
  }

  func testPinnedPanelDoesNotBecomeAnUnrequestedPopoverWhenWindowNarrows() {
    var presentation = TaskSummaryPresentation()
    presentation.resize(to: 1_200)
    presentation.toggle()
    XCTAssertTrue(presentation.showsInline)
    presentation.resize(to: 900)
    XCTAssertFalse(presentation.isVisible)
    XCTAssertFalse(presentation.showsPopover)
    presentation.toggle()
    XCTAssertTrue(presentation.showsPopover)
    presentation.dismissPopover()
    XCTAssertFalse(presentation.isVisible)
    presentation.resize(to: 1_600)
    XCTAssertTrue(presentation.showsInline, "The pinned panel returns when there is room")
    presentation.close()
    XCTAssertFalse(presentation.isVisible)
  }

  func testPopoverDoesNotBecomePinnedWhenWindowWidens() {
    var presentation = TaskSummaryPresentation()
    presentation.resize(to: 900)
    presentation.toggle()
    XCTAssertTrue(presentation.showsPopover)
    presentation.resize(to: 1_200)
    XCTAssertFalse(presentation.isVisible)
    presentation.toggle()
    XCTAssertTrue(presentation.showsInline)
  }
}
