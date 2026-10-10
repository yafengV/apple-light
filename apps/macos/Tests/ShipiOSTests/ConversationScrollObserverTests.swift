import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class ConversationScrollObserverTests: XCTestCase {
  private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
  }

  private final class Recording {
    var events: [ConversationScrollObserver.Event] = []
    var state = ConversationScrollState()
    var followingRequests: [ConversationScrollMetrics] = []
    func receive(_ event: ConversationScrollObserver.Event) {
      events.append(event)
      switch event {
      case .geometry(let metrics):
        if state.observe(metrics) { followingRequests.append(metrics) }
      case .began: state.beginUserScroll()
      case .ended(let metrics): state.endUserScroll(metrics)
      }
    }
    var geometry: [ConversationScrollMetrics] {
      events.compactMap { if case .geometry(let metrics) = $0 { metrics } else { nil } }
    }
    func clear() { events.removeAll(); followingRequests.removeAll() }
  }

  private struct Fixture {
    let window: NSWindow
    let scroll: NSScrollView
    let document: NSView
    let probe: ConversationScrollObserver.Probe
    let recording: Recording
    let snapshot: ConversationScrollSnapshot
    let notificationFlags: [Bool]
  }

  private func fixture(flipped: Bool = true) async throws -> Fixture {
    _ = NSApplication.shared
    let size = NSSize(width: 470, height: 500)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
    scroll.hasVerticalScroller = true
    let frame = NSRect(x: 0, y: 0, width: 470, height: 1200)
    let document: NSView = flipped ? FlippedDocument(frame: frame) : NSView(frame: frame)
    scroll.documentView = document
    window.contentView = scroll
    scroll.layoutSubtreeIfNeeded()
    scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 1200 - scroll.contentView.bounds.height : 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    let flags = [scroll.contentView.postsBoundsChangedNotifications,
      scroll.contentView.postsFrameChangedNotifications, document.postsFrameChangedNotifications]
    let recording = Recording(), probe = ConversationScrollObserver.Probe(frame: .zero)
    let snapshot = ConversationScrollSnapshot()
    probe.snapshot = snapshot
    probe.receive = { recording.receive($0) }
    document.addSubview(probe)
    addTeardownBlock { await MainActor.run { probe.deactivate(); window.close() } }
    try await wait { !recording.geometry.isEmpty }
    XCTAssertTrue(recording.state.isAtBottom)
    XCTAssertTrue(recording.state.followsLatest)
    recording.clear()
    return Fixture(window: window, scroll: scroll, document: document, probe: probe,
      recording: recording, snapshot: snapshot, notificationFlags: flags)
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw AgentFailure(message: "Scroll observer did not deliver its queued event")
      }
      try await Task.sleep(for: .milliseconds(1))
    }
    // Let notifications already queued in this transaction drain as well.
    try await Task.sleep(for: .milliseconds(20))
  }

  func testDeferredGeometryUsesCurrentPositionAfterLayoutAndScrollbarMove() async throws {
    let f = try await fixture()
    f.document.setFrameSize(NSSize(width: 470, height: 1400))
    f.scroll.contentView.scroll(to: .zero)
    f.scroll.reflectScrolledClipView(f.scroll.contentView)
    var sameTurnState = f.recording.state
    XCTAssertFalse(sameTurnState.contentChanged(latest: f.snapshot.metrics),
      "A model revision must see the native history jump before queued geometry is delivered")
    try await wait { !f.recording.geometry.isEmpty }
    XCTAssertTrue(f.recording.geometry.allSatisfy { $0.offset == 0 && $0.contentHeight == 1400 },
      "Queued layout snapshots must not replay the old bottom position")
    XCTAssertTrue(f.recording.followingRequests.isEmpty,
      "A queued layout update must not schedule a jump after the reader moves to history")
    XCTAssertFalse(f.recording.state.followsLatest)
    XCTAssertFalse(f.recording.state.contentChanged())
    XCTAssertTrue(f.recording.state.hasNewContent)
    XCTAssertFalse(f.window.isVisible)
  }

  func testLiveScrollTakesPriorityOverQueuedLayoutAndEndUsesCurrentMetrics() async throws {
    let f = try await fixture()
    f.document.setFrameSize(NSSize(width: 470, height: 1400))
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: f.scroll)
    f.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: f.scroll)
    f.scroll.contentView.scroll(to: .zero)
    f.scroll.reflectScrolledClipView(f.scroll.contentView)
    try await wait { f.recording.events.contains { if case .ended = $0 { true } else { false } } }
    guard case .began? = f.recording.events.first else {
      XCTFail("User scroll must precede an older queued layout update"); return
    }
    let endings = f.recording.events.compactMap { event -> ConversationScrollMetrics? in
      if case .ended(let metrics) = event { return metrics }; return nil
    }
    XCTAssertEqual(endings.map(\.offset), [0])
    XCTAssertTrue(f.recording.followingRequests.isEmpty)
    XCTAssertFalse(f.recording.state.followsLatest)
  }

  func testDismantleDropsQueuedGeometryAndRestoresNativeNotificationFlags() async throws {
    let f = try await fixture()
    f.document.setFrameSize(NSSize(width: 470, height: 1400))
    f.probe.deactivate()
    XCTAssertNil(f.snapshot.metrics)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(f.recording.events.isEmpty)
    XCTAssertEqual([f.scroll.contentView.postsBoundsChangedNotifications,
      f.scroll.contentView.postsFrameChangedNotifications, f.document.postsFrameChangedNotifications],
      f.notificationFlags)
  }

  func testNativeReadingRestoreClampsBothCoordinateDirectionsAndCannotActAfterDismantle() async throws {
    for flipped in [false, true] {
      let f = try await fixture(flipped: flipped)
      let x = f.scroll.contentView.bounds.minX
      let restored = try XCTUnwrap(f.snapshot.restore(offset: 120))
      XCTAssertEqual(restored.offset, 120, accuracy: 1)
      XCTAssertEqual(f.scroll.contentView.bounds.minX, x)
      let bottom = try XCTUnwrap(f.snapshot.restore(offset: 99999))
      XCTAssertEqual(bottom.offset, bottom.contentHeight - bottom.viewportHeight, accuracy: 1)
      XCTAssertEqual(try XCTUnwrap(f.snapshot.restore(offset: -100)).offset, 0, accuracy: 1)
      XCTAssertNil(f.snapshot.restore(offset: .infinity))
      XCTAssertEqual(try XCTUnwrap(f.snapshot.metrics).offset, 0, accuracy: 1)
      f.probe.deactivate()
      XCTAssertNil(f.snapshot.restore(offset: 120))
      XCTAssertFalse(f.window.isVisible)
    }
  }
}
