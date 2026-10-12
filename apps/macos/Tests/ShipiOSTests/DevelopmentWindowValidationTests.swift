#if DEBUG
import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class DevelopmentWindowValidationTests: XCTestCase {
  func testWindowSetupRequiresExplicitIsolatedLaunchAndFixedMatrixSize() {
    XCTAssertNil(DevelopmentWindowValidation.requestedSize(arguments: ["ShipiOS"]))
    for arguments in [
      ["ShipiOS", "--validation-window-size", "1000x700"],
      ["ShipiOS", "--data-root", "relative", "--validation-window-size", "1000x700"],
      ["ShipiOS", "--data-root", "/tmp/fixture", "--validation-window-size"],
      ["ShipiOS", "--data-root", "/tmp/fixture", "--validation-window-size", "900x500"],
      ["ShipiOS", "--data-root", "/tmp/fixture", "--validation-window-size", "1000x700", "--validation-window-size", "1280x800"],
    ] { XCTAssertNil(DevelopmentWindowValidation.requestedSize(arguments: arguments)) }
  }

  func testValidationPlacementKeepsFittingFrameAndMovesFromSmallDisplay() throws {
    let large = NSRect(x: 0, y: 40, width: 1600, height: 1000)
    let small = NSRect(x: 1600, y: 40, width: 1024, height: 738)
    let size = NSSize(width: 1280, height: 800)
    let current = NSRect(x: 100, y: 100, width: 1280, height: 800)
    XCTAssertEqual(DevelopmentWindowValidation.targetFrame(current: current, size: size,
      visibleFrames: [small, large]), current)
    let moved = try XCTUnwrap(DevelopmentWindowValidation.targetFrame(
      current: .init(x: 1620, y: 60, width: 1000, height: 700), size: size,
      visibleFrames: [small, large]))
    XCTAssertEqual(moved.size, size); XCTAssertTrue(large.contains(moved))
    XCTAssertEqual(moved.minX, 320)
  }

  func testUnavailableSizeDoesNotProduceClippedOrSpanningFrame() {
    let current = NSRect(x: -900, y: 20, width: 1000, height: 700)
    XCTAssertNil(DevelopmentWindowValidation.targetFrame(current: current,
      size: .init(width: 1280, height: 800), visibleFrames: [
        .init(x: -1024, y: 0, width: 1024, height: 768),
        .init(x: 0, y: 0, width: 1280, height: 798)]))
    XCTAssertNil(DevelopmentWindowValidation.targetFrame(current: current,
      size: .init(width: 1000, height: 700), visibleFrames: []))
  }

  func testMainWindowReportsActualFrameWithoutResizingAnotherWindowOrTakingFocus() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let main = NSWindow(contentRect: .init(x: 20, y: 30, width: 1120, height: 780),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .init(x: 40, y: 50, width: 760, height: 720),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    main.isReleasedWhenClosed = false; other.isReleasedWhenClosed = false
    main.identifier = .init("main"); other.identifier = .init("task")
    main.orderFront(nil); other.makeKeyAndOrderFront(nil)
    defer { main.close(); other.close() }
    let otherFrame = other.frame
    let responder = main.firstResponder, key = NSApp.keyWindow
    let originalFrame = main.frame
    try DevelopmentWindowValidation.prepare(arguments: ["ShipiOS", "--data-root", root.path],
      dataRoot: root, windows: [other, main])
    XCTAssertEqual(main.frame, originalFrame)
    XCTAssertEqual(other.frame, otherFrame)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("validation-window.json").path))
    for (argument, size) in [("1000x700", NSSize(width: 1000, height: 700)),
      ("1280x800", NSSize(width: 1280, height: 800))] {
      let before = main.frame, screens = NSScreen.screens.map(\.visibleFrame)
      let expected = DevelopmentWindowValidation.targetFrame(current: before, size: size,
        visibleFrames: screens)
      try DevelopmentWindowValidation.prepare(arguments: ["ShipiOS", "--data-root", root.path,
        "--validation-window-size", argument], dataRoot: root, windows: [other, main])
      if let expected {
        XCTAssertEqual(main.frame, expected)
        XCTAssertEqual(main.frame.size, size)
      } else { XCTAssertEqual(main.frame, before) }
      XCTAssertEqual(other.frame, otherFrame)
      XCTAssertTrue(main.firstResponder === responder)
      XCTAssertTrue(NSApp.keyWindow === key)
      let data = try Data(contentsOf: root.appendingPathComponent("validation-window.json"))
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(record["matchesRequestedFrame"] as? Bool, main.frame.size == size)
      XCTAssertEqual(record["targetDisplayAvailable"] as? Bool, expected != nil)
      XCTAssertEqual(record["fullyVisibleOnOneScreen"] as? Bool,
        screens.contains(where: { $0.contains(main.frame) }))
      XCTAssertEqual(record["actualWidth"] as? Double, main.frame.width)
      XCTAssertEqual(record["actualHeight"] as? Double, main.frame.height)
    }
  }
}
#endif
