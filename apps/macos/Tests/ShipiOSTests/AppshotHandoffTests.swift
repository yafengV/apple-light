import AppKit
import SwiftUI
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
    owner.orderFront(nil)
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

  @MainActor func testEarlyScreenshotKeepsPlaceholderIDUntilFinalMetadataIsSaved() async throws {
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
    owner.isReleasedWhenClosed = false
    owner.orderFront(nil)
    defer { owner.close() }
    let bytes = try AttachmentFixture.png()
    let source = CGRect(x: 100, y: 100, width: 500, height: 300)
    let screenshot = AppshotCaptureResult(data: bytes, name: "Example Appshot.png",
      sourceFrame: source)
    let context = AppshotContext(appName: "Example", bundleIdentifier: "example.app",
      windowTitle: "Window", axTree: "window text")
    let final = AppshotCaptureResult(data: bytes, name: screenshot.name,
      context: context, sourceFrame: source)
    var release: CheckedContinuation<AppshotCaptureResult?, Never>?
    let ready = expectation(description: "screenshot published before AX result")
    let capture = Task {
      await store.captureAppshotWithProgress(draft: "task", ownerWindow: owner) { progress in
        progress(screenshot)
        return await withCheckedContinuation { continuation in
          release = continuation
          ready.fulfill()
        }
      }
    }
    await fulfillment(of: [ready], timeout: 2)
    let pending = try XCTUnwrap(store.pendingAppshot)
    XCTAssertEqual(pending.draftKey, "task")
    XCTAssertEqual(pending.screenshot, bytes)
    XCTAssertNil(store.library.draftImages["task"])
    let pendingView = NSHostingView(rootView: ImageAttachmentsView(store: store,
      images: [], removable: true, draftKey: "task"))
    XCTAssertGreaterThan(pendingView.fittingSize.height, 100,
      "An early screenshot must reserve its composer card before the attachment is saved")
    XCTAssertEqual(store.appshotHandoff?.imageID, pending.id)
    XCTAssertTrue(store.appshotHandoff?.ownerWindow === owner)
    release?.resume(returning: final)
    await capture.value
    XCTAssertNil(store.pendingAppshot)
    let attachment = try XCTUnwrap(store.library.draftImages["task"]?.last)
    XCTAssertEqual(attachment.id, pending.id)
    XCTAssertEqual(attachment.appshot, context)
    XCTAssertEqual(try ImageAttachmentStorage.data(attachment, root: root), bytes)

    let cancelled = expectation(description: "second screenshot published")
    var releaseCancel: CheckedContinuation<AppshotCaptureResult?, Never>?
    let cancelCapture = Task {
      await store.captureAppshotWithProgress(draft: "other", ownerWindow: owner) { progress in
        progress(screenshot)
        return await withCheckedContinuation { continuation in
          releaseCancel = continuation
          cancelled.fulfill()
        }
      }
    }
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertNotNil(store.pendingAppshot)
    releaseCancel?.resume(returning: nil)
    await cancelCapture.value
    XCTAssertNil(store.pendingAppshot)
    XCTAssertNil(store.appshotHandoff)
    XCTAssertNil(store.library.draftImages["other"])
    await store.shutdown()
  }

  @MainActor func testEarlyScreenshotFailureRemovesTransientCard() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let screenshot = AppshotCaptureResult(data: try AttachmentFixture.png(),
      name: "Failed Appshot.png", sourceFrame: CGRect(x: 0, y: 0, width: 200, height: 100))
    await store.captureAppshotWithProgress(draft: "task") { progress in
      progress(screenshot)
      throw AgentFailure(message: "capture failed")
    }
    XCTAssertNil(store.pendingAppshot)
    XCTAssertNil(store.appshotHandoff)
    XCTAssertNil(store.library.draftImages["task"])
    XCTAssertFalse(store.importingImages)
    XCTAssertEqual(store.error, "capture failed")
    await store.shutdown()
  }
}
