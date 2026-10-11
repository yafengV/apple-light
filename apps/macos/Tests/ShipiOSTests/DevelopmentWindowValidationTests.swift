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

  func testMainWindowGetsExactFrameWithoutResizingAnotherWindowOrTakingFocus() throws {
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
    let otherFrame = other.frame, top = main.frame.maxY
    let responder = main.firstResponder, key = NSApp.keyWindow
    let originalFrame = main.frame
    try DevelopmentWindowValidation.prepare(arguments: ["ShipiOS", "--data-root", root.path],
      dataRoot: root, windows: [other, main])
    XCTAssertEqual(main.frame, originalFrame)
    XCTAssertEqual(other.frame, otherFrame)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("validation-window.json").path))
    for (argument, size) in [("1000x700", NSSize(width: 1000, height: 700)),
      ("1280x800", NSSize(width: 1280, height: 800))] {
      try DevelopmentWindowValidation.prepare(arguments: ["ShipiOS", "--data-root", root.path,
        "--validation-window-size", argument], dataRoot: root, windows: [other, main])
      XCTAssertEqual(main.frame.size, size)
      XCTAssertEqual(main.frame.maxY, top)
      XCTAssertEqual(other.frame, otherFrame)
      XCTAssertTrue(main.firstResponder === responder)
      XCTAssertTrue(NSApp.keyWindow === key)
      let data = try Data(contentsOf: root.appendingPathComponent("validation-window.json"))
      let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(record["matchesRequestedFrame"] as? Bool, true)
      XCTAssertEqual(record["actualWidth"] as? Double, size.width)
      XCTAssertEqual(record["actualHeight"] as? Double, size.height)
    }
  }
}
#endif
