import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TerminalHostFocusTests: XCTestCase {
  private final class TestWindow: NSWindow {
    var active = true
    var rejectsTerminal = false
    override var isKeyWindow: Bool { active }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
      if rejectsTerminal && responder is SessionTerminalView { return false }
      return super.makeFirstResponder(responder)
    }
  }
  private func fixture() -> (TestWindow, SessionTerminalView, TerminalHost.Coordinator) {
    _ = NSApplication.shared
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .init(x: 0, y: 0, width: 500, height: 300))
    return (window, SessionTerminalView(frame: .init(x: 0, y: 0, width: 500, height: 250)),
      TerminalHost.Coordinator())
  }
  private func request() -> TerminalFocusRequest {
    .init(scope: .init(root: URL(fileURLWithPath: "/tmp"), conversation: "task"))
  }
  private func flush() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  func testPendingRequestSurvivesDetachedViewAndFocusesOnAttachment() async {
    let (window, view, coordinator) = fixture()
    defer { coordinator.detach(); window.close() }
    let first = request()
    coordinator.update(view: view, request: first, canFocus: { $0 == first })
    await flush()
    XCTAssertNil(coordinator.handled)
    XCTAssertNil(view.window)
    window.contentView?.addSubview(view)
    await flush()
    XCTAssertTrue(window.firstResponder === view)
    XCTAssertEqual(coordinator.handled, first.id)

    view.removeFromSuperview()
    let second = request()
    coordinator.update(view: view, request: second, canFocus: { $0 == second })
    await flush()
    XCTAssertEqual(coordinator.handled, first.id)
    window.contentView?.addSubview(view)
    await flush()
    XCTAssertTrue(window.firstResponder === view)
    XCTAssertEqual(coordinator.handled, second.id)
  }

  func testLatestRequestAndPermissionAreReadWhenCallbackRuns() async {
    let (window, view, coordinator) = fixture()
    defer { coordinator.detach(); window.close() }
    let old = request(), latest = request()
    var allowed = true
    coordinator.update(view: view, request: old, canFocus: { _ in true })
    coordinator.update(view: view, request: latest, canFocus: { $0 == latest && allowed })
    allowed = false
    window.contentView?.addSubview(view)
    window.makeFirstResponder(nil)
    await flush()
    XCTAssertNil(coordinator.handled)
    XCTAssertFalse(window.firstResponder === view)
    allowed = true
    coordinator.update(view: view, request: latest, canFocus: { $0 == latest && allowed })
    await flush()
    XCTAssertEqual(coordinator.handled, latest.id)
    XCTAssertTrue(window.firstResponder === view)
  }

  func testDismantledHostCannotClearReplacementOrRunItsQueuedFocus() async {
    let (window, view, old) = fixture()
    let replacement = TerminalHost.Coordinator()
    defer { replacement.detach(); window.close() }
    old.update(view: view, request: request(), canFocus: { _ in true })
    let current = request()
    replacement.update(view: view, request: current, canFocus: { $0 == current })
    old.detach()
    XCTAssertTrue(view.focusCoordinator === replacement)
    window.contentView?.addSubview(view)
    await flush()
    XCTAssertNil(old.handled)
    XCTAssertEqual(replacement.handled, current.id)
    XCTAssertTrue(window.firstResponder === view)
  }

  func testCancelledRequestAndInactiveWindowCannotAcquireFocus() async {
    let (window, view, coordinator) = fixture()
    defer { coordinator.detach(); window.close() }
    coordinator.update(view: view, request: request(), canFocus: { _ in true })
    coordinator.update(view: view, request: nil, canFocus: { _ in true })
    window.contentView?.addSubview(view)
    window.makeFirstResponder(nil)
    await flush()
    XCTAssertNil(coordinator.handled)
    XCTAssertFalse(window.firstResponder === view)
    window.active = false
    coordinator.update(view: view, request: request(), canFocus: { _ in true })
    await flush()
    XCTAssertNil(coordinator.handled)
    XCTAssertFalse(window.firstResponder === view)
  }

  func testHandledRequestDoesNotStealFocusOnUnrelatedUpdate() async {
    let (window, view, coordinator) = fixture()
    defer { coordinator.detach(); window.close() }
    let focus = request()
    window.contentView?.addSubview(view)
    coordinator.update(view: view, request: focus, canFocus: { _ in true })
    await flush()
    XCTAssertTrue(window.firstResponder === view)
    let input = NSTextView(frame: .init(x: 0, y: 260, width: 300, height: 30))
    window.contentView?.addSubview(input)
    XCTAssertTrue(window.makeFirstResponder(input))
    coordinator.update(view: view, request: focus, canFocus: { _ in true })
    await flush()
    XCTAssertTrue(window.firstResponder === input)
  }

  func testRejectedFocusRemainsPendingAndDismantleCancelsQueuedRetry() async {
    let (window, view, coordinator) = fixture()
    defer { coordinator.detach(); window.close() }
    window.rejectsTerminal = true
    window.contentView?.addSubview(view)
    let focus = request()
    coordinator.update(view: view, request: focus, canFocus: { _ in true })
    await flush()
    XCTAssertNil(coordinator.handled)
    XCTAssertFalse(window.firstResponder === view)
    window.rejectsTerminal = false
    coordinator.update(view: view, request: focus, canFocus: { _ in true })
    await flush()
    XCTAssertEqual(coordinator.handled, focus.id)
    XCTAssertTrue(window.firstResponder === view)
    window.makeFirstResponder(nil)
    coordinator.update(view: view, request: request(), canFocus: { _ in true })
    coordinator.detach()
    await flush()
    XCTAssertNil(view.focusCoordinator)
    XCTAssertFalse(window.firstResponder === view)
  }
}
