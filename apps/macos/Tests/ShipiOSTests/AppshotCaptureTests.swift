import AppKit
import XCTest

@testable import ShipiOS

final class AppshotCaptureTests: XCTestCase {
  func testScreenshotDimensionsStayWithinAttachmentBounds() {
    let small = AppshotImage.size(rect: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 2)
    XCTAssertEqual(small.width, 1_600)
    XCTAssertEqual(small.height, 1_200)
    let large = AppshotImage.size(rect: CGRect(x: 0, y: 0, width: 5_000, height: 2_500), pixelScale: 2)
    XCTAssertEqual(large.width, 3_200)
    XCTAssertEqual(large.height, 1_600)
  }

  func testAutomaticCaptureUsesFrontmostEligibleWindowForRecordedApp() {
    func window(_ pid: Int, _ id: Int, _ layer: Int, _ width: Int) -> [String: Any] {
      [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
        kCGWindowLayer as String: layer,
        kCGWindowBounds as String: ["Width": width, "Height": 400]]
    }
    let windows = [window(7, 11, 0, 800), window(42, 12, 1, 800),
      window(42, 13, 0, 30), window(42, 14, 0, 800), window(42, 15, 0, 900)]
    XCTAssertEqual(AppshotImage.frontWindowID(for: 42, windows: windows), 14)
    XCTAssertNil(AppshotImage.frontWindowID(for: 99, windows: windows))
  }

  func testCapturedImageCanEnterExistingAttachmentStorage() throws {
    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let result = try AppshotImage.encode(context.makeImage()!, applicationName: "Example App")
    XCTAssertEqual(result.name, "Example App 截图.png")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stored = try ImageAttachmentStorage.importData(result.data, name: result.name, root: root)
    XCTAssertEqual(stored.name, result.name)
    XCTAssertEqual(try ImageAttachmentStorage.data(stored, root: root), result.data)
  }

  @MainActor func testCaptureCommandIsOwnedByTaskWindowAndRequiresChatWorkspace() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertTrue(TaskWindowCommandContext.owns("capture-appshot"))
    XCTAssertTrue(store.commandEnabled("capture-appshot"))
    store.importingImages = true
    XCTAssertFalse(store.commandEnabled("capture-appshot"))
    store.importingImages = false
    store.destination = .settings
    XCTAssertFalse(store.commandEnabled("capture-appshot"))
    await store.shutdown()
  }

  @MainActor func testCaptureKeepsSelectedDraftAndCancellationAddsNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "first", project: "", title: "First", runIDs: []),
      .init(id: "second", project: "", title: "Second", runIDs: [])]
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let result = try AppshotImage.encode(context.makeImage()!, applicationName: "Sample")
    await store.captureAppshot(draft: "second") { result }
    XCTAssertEqual(store.library.draftImages["second"]?.count, 1)
    XCTAssertNil(store.library.draftImages["first"])
    await store.captureAppshot(draft: "first") { nil }
    XCTAssertNil(store.library.draftImages["first"])
    XCTAssertFalse(store.importingImages)
    await store.shutdown()
  }
}
