import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestCodeScrollAnchorTests: XCTestCase {
  private final class Document: NSView {
    override var isFlipped: Bool { true }
  }
  private func fixture() -> (NSWindow, NSScrollView, Document, PullRequestCodeScrollAnchorView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 600, height: 400))
    scroll.hasVerticalScroller = true
    let document = Document(frame: .init(x: 0, y: 0, width: 600, height: 3_000))
    let anchor = PullRequestCodeScrollAnchorView(frame: .init(x: 0, y: 1_700, width: 1, height: 0))
    document.addSubview(anchor); scroll.documentView = document; window.contentView = scroll
    return (window, scroll, document, anchor)
  }
  private func waitUntilVisible(_ anchor: NSView, in scroll: NSScrollView) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !scroll.contentView.bounds.intersects(anchor.convert(anchor.bounds, to: scroll.documentView)) {
      guard ContinuousClock.now < deadline else { XCTFail("Requested code line never became visible"); return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testLineBecomingMeasurableAfterInitialLayoutRetriesStillNavigatesOnce() async throws {
    let (window, scroll, _, anchor) = fixture(); defer { window.close() }
    anchor.request = UUID()
    // Lazy code sections can remain unmeasurable past the initial retry window.
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    anchor.setFrameSize(.init(width: 1, height: 20))
    anchor.layoutSubtreeIfNeeded()
    try await waitUntilVisible(anchor, in: scroll)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)
    try await Task.sleep(for: .milliseconds(150))
    scroll.contentView.scroll(to: .init(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
    anchor.needsLayout = true; anchor.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(scroll.contentView.bounds.minY, 200, accuracy: 1,
      "Completed navigation must not pull subsequent user scrolling back to the line")
    XCTAssertFalse(window.isVisible)
  }

  func testCancelledLateLayoutCannotNavigateButReplacementRequestCan() async throws {
    let (window, scroll, _, anchor) = fixture(); defer { window.close() }
    anchor.request = UUID()
    try await Task.sleep(for: .milliseconds(300))
    anchor.request = nil
    anchor.setFrameSize(.init(width: 1, height: 20)); anchor.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    anchor.request = UUID()
    try await waitUntilVisible(anchor, in: scroll)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)
    XCTAssertFalse(window.isVisible)
  }

  func testClampedScrollDoesNotCompleteBeforeTheLazyDocumentGrows() async throws {
    let (window, scroll, document, anchor) = fixture(); defer { window.close() }
    document.setFrameSize(.init(width: 600, height: 400))
    anchor.setFrameSize(.init(width: 1, height: 20))
    anchor.request = UUID()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(scroll.contentView.bounds.intersects(anchor.convert(anchor.bounds, to: document)))
    document.setFrameSize(.init(width: 600, height: 3_000))
    try await waitUntilVisible(anchor, in: scroll)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)
    XCTAssertFalse(window.isVisible)
  }

  func testDetachedLateTargetCannotScrollItsFormerDocument() async throws {
    let (window, scroll, _, anchor) = fixture(); defer { window.close() }
    anchor.request = UUID()
    try await Task.sleep(for: .milliseconds(300))
    anchor.removeFromSuperview()
    anchor.setFrameSize(.init(width: 1, height: 20)); anchor.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(anchor.window)
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
  }

  func testLayoutInvalidatedByFirstScrollIsCheckedAgainBeforeCompleting() async throws {
    let (window, scroll, _, anchor) = fixture(); defer { window.close() }
    anchor.setFrameSize(.init(width: 1, height: 20))
    scroll.contentView.postsBoundsChangedNotifications = true
    var invalidated = false
    let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
      object: scroll.contentView, queue: .main) { _ in
        MainActor.assumeIsolated {
          guard !invalidated, scroll.contentView.bounds.minY > 1_000 else { return }
          invalidated = true
          anchor.setFrameSize(.init(width: 1, height: 0))
        }
      }
    defer { NotificationCenter.default.removeObserver(observer) }
    anchor.request = UUID()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !invalidated, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(invalidated)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(300))
    anchor.setFrameSize(.init(width: 1, height: 20))
    try await waitUntilVisible(anchor, in: scroll)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)
  }

  func testHorizontallyHiddenGutterDoesNotKeepPullingVerticalPositionBack() async throws {
    let (window, scroll, _, anchor) = fixture(); defer { window.close() }
    // Horizontal code scrolling can put the gutter outside the page's X range.
    // Navigation still addresses the line's vertical position only.
    anchor.setFrameOrigin(.init(x: -200, y: 1_700))
    anchor.setFrameSize(.init(width: 1, height: 20))
    anchor.request = UUID()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while scroll.contentView.bounds.minY < 1_000, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 1_000)
    try await Task.sleep(for: .milliseconds(150))
    scroll.contentView.scroll(to: .init(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(scroll.contentView.bounds.minY, 200, accuracy: 1,
      "An offscreen gutter must not keep an already completed vertical navigation alive")
  }
}
