import AppKit
import XCTest

@testable import ShipiOS

final class AppshotHandoffTests: XCTestCase {
  func testHandoffSpringUsesReferenceResponseAndDamping() {
    let spring = AppshotHandoffMotion.spring(keyPath: "position",
      from: NSValue(point: CGPoint(x: 0, y: 0)),
      to: NSValue(point: CGPoint(x: 100, y: 50)))
    let frequency = 2 * Double.pi / 0.35
    XCTAssertEqual(AppshotHandoffMotion.delay, 0.15)
    XCTAssertEqual(spring.mass, 1)
    XCTAssertEqual(spring.stiffness, frequency * frequency, accuracy: 0.001)
    XCTAssertEqual(spring.damping, 2 * 0.73 * frequency, accuracy: 0.001)
    XCTAssertGreaterThanOrEqual(spring.duration, 0.3)
    XCTAssertLessThanOrEqual(spring.duration, 1.2)
    XCTAssertEqual(spring.fillMode, .backwards)
  }

  func testCaptureCoordinatesMapToAppKitAcrossDisplays() {
    let primary = AppshotHandoffGeometry.Display(
      captureFrame: CGRect(x: 0, y: 0, width: 1500, height: 1000),
      appFrame: CGRect(x: 0, y: 0, width: 1500, height: 1000))
    let secondary = AppshotHandoffGeometry.Display(
      captureFrame: CGRect(x: -1000, y: 0, width: 1000, height: 800),
      appFrame: CGRect(x: -1000, y: 200, width: 1000, height: 800))
    let displays = [primary, secondary]
    XCTAssertEqual(AppshotHandoffGeometry.appFrame(
      for: CGRect(x: 100, y: 200, width: 400, height: 300), displays: displays),
      CGRect(x: 100, y: 500, width: 400, height: 300))
    XCTAssertEqual(AppshotHandoffGeometry.appFrame(
      for: CGRect(x: -900, y: 100, width: 300, height: 200), displays: displays),
      CGRect(x: -900, y: 700, width: 300, height: 200))
    XCTAssertNil(AppshotHandoffGeometry.appFrame(
      for: CGRect(x: 4000, y: 0, width: 200, height: 200), displays: displays))
  }

  @MainActor func testCaptureHandoffBelongsToOriginWindowAndRespectsReducedMotion() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    var appearance = store.appearance
    appearance.reduceMotion = .off
    store.appearance = appearance
    let owner = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
    defer { owner.close(); other.close() }
    let metadata = AppshotContext(appName: "Example", bundleIdentifier: nil,
      windowTitle: "Window", axTree: "")
    let captured = AppshotCaptureResult(data: try AttachmentFixture.png(),
      name: "Example Appshot.png", context: metadata,
      sourceFrame: CGRect(x: 100, y: 100, width: 500, height: 300))
    await store.captureAppshot(draft: "task", ownerWindow: owner) { captured }
    let handoff = try XCTUnwrap(store.appshotHandoff)
    XCTAssertTrue(handoff.ownerWindow === owner)
    XCTAssertEqual(handoff.imageID, store.library.draftImages["task"]?.last?.id)
    store.startAppshotHandoff(imageID: handoff.imageID,
      destinationFrame: CGRect(x: 50, y: 50, width: 232, height: 140), window: other)
    XCTAssertEqual(store.appshotHandoff?.imageID, handoff.imageID,
      "A second task window must not consume another window's capture")

    store.appshotHandoff = nil
    appearance.reduceMotion = .on
    store.appearance = appearance
    await store.captureAppshot(draft: "task", ownerWindow: owner) { captured }
    XCTAssertNil(store.appshotHandoff)
    await store.shutdown()
  }

  @MainActor func testAnchorReportsOwningWindowCoordinatesWithoutAcceptingClicks() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 40, y: 60, width: 440, height: 320),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let anchor = AppshotHandoffAnchor.AnchorView(frame: CGRect(x: 20, y: 30, width: 232, height: 140))
    window.contentView = anchor
    var reported: CGRect?
    var owner: NSWindow?
    anchor.report = { frame, current in reported = frame; owner = current }
    anchor.schedule()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(owner === window)
    XCTAssertEqual(reported, window.convertToScreen(anchor.convert(anchor.bounds, to: nil)))
    XCTAssertNil(anchor.hitTest(.zero))
  }
}
