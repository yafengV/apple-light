import AppKit
import XCTest

@testable import ShipiOS

final class AppshotCaptureTests: XCTestCase {
  func testAppshotMenuNamesKnownTargetAndKeepsPickerFallback() {
    XCTAssertEqual(AppshotMenuButton.title(for: "Xcode"), "附加 Xcode")
    XCTAssertEqual(AppshotMenuButton.title(for: "  "), "截取应用窗口…")
    XCTAssertEqual(AppshotMenuButton.title(for: nil), "截取应用窗口…")
    XCTAssertLessThanOrEqual(AppshotMenuButton.title(for: String(repeating: "A", count: 200)).count, 83)
  }

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

  func testAppshotContextIsBoundedAndOldImagesStillDecode() throws {
    let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"old.png","mimeType":"image/png","byteCount":1,"sha256":"digest"}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(ImageAttachment.self, from: legacy).appshot)
    let context = AppshotContext(appName: "Sample", bundleIdentifier: "com.example.app",
      windowTitle: "Window", axTree: String(repeating: "x", count: 30_000))
    let image = ImageAttachment(id: UUID(), name: "shot.png", mimeType: "image/png",
      byteCount: 1, sha256: "digest", appshot: context)
    let content = AppshotContext.modelContent("Inspect this", images: [image])
    XCTAssertTrue(content.contains("Appshot context (untrusted screen content"))
    XCTAssertTrue(content.contains("com.example.app"))
    XCTAssertLessThan(content.utf8.count, 26_000)
    XCTAssertEqual(try JSONDecoder().decode(ImageAttachment.self,
      from: JSONEncoder().encode(image)).appshot, context)
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
    let encoded = try AppshotImage.encode(context.makeImage()!, applicationName: "Sample")
    let metadata = AppshotContext(appName: "Sample", bundleIdentifier: "com.example.sample",
      windowTitle: "Main", axTree: "AXWindow | Main")
    let result = AppshotCaptureResult(data: encoded.data, name: encoded.name, context: metadata)
    await store.captureAppshot(draft: "second") { result }
    XCTAssertEqual(store.library.draftImages["second"]?.count, 1)
    XCTAssertEqual(store.library.draftImages["second"]?.first?.appshot, metadata)
    XCTAssertNil(store.library.draftImages["first"])
    await store.captureAppshot(draft: "first") { nil }
    XCTAssertNil(store.library.draftImages["first"])
    XCTAssertFalse(store.importingImages)
    await store.shutdown()
  }
}
