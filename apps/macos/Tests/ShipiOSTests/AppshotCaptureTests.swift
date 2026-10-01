import AppKit
import SwiftUI
import XCTest

@testable import ShipiOS

final class AppshotCaptureTests: XCTestCase {
  func testAppshotMenuNamesKnownTargetAndKeepsPickerFallback() {
    XCTAssertEqual(AppshotMenuButton.title(for: "Xcode"), "附加 Xcode")
    XCTAssertEqual(AppshotMenuButton.title(for: "  "), "截取应用窗口…")
    XCTAssertEqual(AppshotMenuButton.title(for: nil), "截取应用窗口…")
    XCTAssertLessThanOrEqual(AppshotMenuButton.title(for: String(repeating: "A", count: 200)).count, 83)
    XCTAssertFalse(AppshotMenuButton.isEnabled(hasTarget: false, imageCount: 0))
    XCTAssertTrue(AppshotMenuButton.isEnabled(hasTarget: true, imageCount: 0))
    XCTAssertFalse(AppshotMenuButton.isEnabled(hasTarget: true,
      imageCount: ImageAttachmentStorage.maxCount))
  }

  func testScreenshotDimensionsStayWithinAttachmentBounds() {
    let small = AppshotImage.size(rect: CGRect(x: 0, y: 0, width: 800, height: 600), pixelScale: 2)
    XCTAssertEqual(small.width, 1_600)
    XCTAssertEqual(small.height, 1_200)
    let large = AppshotImage.size(rect: CGRect(x: 0, y: 0, width: 5_000, height: 2_500), pixelScale: 2)
    XCTAssertEqual(large.width, 3_200)
    XCTAssertEqual(large.height, 1_600)
  }

  func testCaptureRetainsUsableSourceWindowFrameForHandoff() {
    let window = CGRect(x: -420, y: 30, width: 860, height: 540)
    let content = CGRect(x: 0, y: 0, width: 800, height: 500)
    XCTAssertEqual(AppshotImage.sourceFrame(windowFrame: window, contentRect: content), window)
    XCTAssertEqual(AppshotImage.sourceFrame(windowFrame: .zero, contentRect: content), content)
    XCTAssertNil(AppshotImage.sourceFrame(windowFrame: CGRect(x: CGFloat.nan, y: 0, width: 800, height: 500),
      contentRect: .zero))
    XCTAssertNil(AppshotImage.sourceFrame(windowFrame: nil,
      contentRect: CGRect(x: 0, y: 0, width: 30_000, height: 500)))
  }

  func testAccessibilitySelectsUntitledWindowByUniqueFrame() {
    let target = CGRect(x: -480, y: 120, width: 700, height: 510)
    let candidates = [
      AppshotAccessibility.WindowCandidate(title: "Other",
        frame: CGRect(x: 400, y: 80, width: 700, height: 510)),
      AppshotAccessibility.WindowCandidate(title: nil,
        frame: CGRect(x: -475, y: 124, width: 700, height: 510)),
    ]
    XCTAssertEqual(AppshotAccessibility.selectedIndex(candidates, title: nil, frame: target), 1)
    XCTAssertEqual(AppshotAccessibility.selectedIndex(candidates, title: "", frame: target), 1)
    XCTAssertNil(AppshotAccessibility.selectedIndex(candidates, title: nil, frame: nil))
  }

  func testAccessibilityRequiresUniqueWindowAndRejectsStaleTitle() {
    let target = CGRect(x: 100, y: 100, width: 600, height: 400)
    let candidates = [
      AppshotAccessibility.WindowCandidate(title: "Document", frame: target),
      AppshotAccessibility.WindowCandidate(title: "Document",
        frame: CGRect(x: 900, y: 100, width: 600, height: 400)),
    ]
    XCTAssertEqual(AppshotAccessibility.selectedIndex(candidates,
      title: "Document", frame: target), 0)
    XCTAssertNil(AppshotAccessibility.selectedIndex(candidates,
      title: "Document", frame: nil), "Duplicate titles cannot identify a window")
    XCTAssertNil(AppshotAccessibility.selectedIndex([
      .init(title: "Document", frame: target), .init(title: "Other", frame: target)],
      title: nil, frame: target), "Overlapping AX windows are ambiguous")
    XCTAssertEqual(AppshotAccessibility.selectedIndex([
      .init(title: "Stale", frame: CGRect(x: 900, y: 100, width: 600, height: 400)),
      .init(title: "Actual", frame: target)], title: "Stale", frame: target), 1)
  }

  func testAppshotCardUsesReferenceFitHeightForWideAndTallWindows() {
    XCTAssertEqual(AppshotCardLayout.screenshotHeight(pixelWidth: 800, pixelHeight: 200), 58,
      accuracy: 0.001)
    XCTAssertEqual(AppshotCardLayout.screenshotHeight(pixelWidth: 400, pixelHeight: 800), 140)
    XCTAssertEqual(AppshotCardLayout.screenshotHeight(pixelWidth: 0, pixelHeight: 800), 140)
  }

  @MainActor func testWideAppshotCardRendersInNativeHost() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let graphics = try XCTUnwrap(CGContext(data: nil, width: 800, height: 200,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    graphics.setFillColor(NSColor.systemRed.cgColor)
    graphics.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
    let encoded = try AppshotImage.encode(try XCTUnwrap(graphics.makeImage()), applicationName: "Example")
    let metadata = AppshotContext(appName: "Example", bundleIdentifier: nil,
      windowTitle: "Wide Window", axTree: "")
    let attachment = try ImageAttachmentStorage.importData(encoded.data,
      name: encoded.name, root: root, appshot: metadata)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 190),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: AppshotCardVisual(
      image: attachment, context: metadata, root: root).frame(width: 300, height: 190))
    window.contentView = host
    host.frame = window.contentView!.bounds
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(png.count, 2_000)
    let rendered = try XCTUnwrap(NSBitmapImageRep(data: png))
    let redRows = (0..<rendered.pixelsHigh).filter { row in
      guard let color = rendered.colorAt(x: 150, y: row)?.usingColorSpace(.deviceRGB) else { return false }
      return color.redComponent > 0.6 && color.greenComponent < 0.3
    }
    XCTAssertGreaterThan(try XCTUnwrap(redRows.first), 95,
      "A wide screenshot should rest at the bottom of the 140pt Appshot card")
    XCTAssertGreaterThan(try XCTUnwrap(redRows.last), 135)
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_APPSHOT_SNAPSHOTS"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("wide-card.png"))
    }
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

  func testFrontmostAppDoesNotExpireWhileItRemainsForeground() {
    let now = Date(timeIntervalSince1970: 1_000)
    let stale = now.addingTimeInterval(-600)
    XCTAssertEqual(AppshotTargetOrder.pids(frontmost: 42, cached: 42, cachedAt: stale,
      now: now, ownPID: 7), [42])
    XCTAssertEqual(AppshotTargetOrder.pids(frontmost: 43, cached: 42,
      cachedAt: now.addingTimeInterval(-20), now: now, ownPID: 7), [43, 42])
    XCTAssertEqual(AppshotTargetOrder.pids(frontmost: 7, cached: 42,
      cachedAt: now.addingTimeInterval(-20), now: now, ownPID: 7), [42])
    XCTAssertEqual(AppshotTargetOrder.pids(frontmost: 7, cached: 42, cachedAt: stale,
      now: now, ownPID: 7), [])
  }

  func testCapturedImageCanEnterExistingAttachmentStorage() throws {
    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let result = try AppshotImage.encode(context.makeImage()!, applicationName: "Example App",
      at: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(result.name, "Example App Appshot 1970-01-01T00-00-00.000Z.png")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stored = try ImageAttachmentStorage.importData(result.data, name: result.name, root: root)
    XCTAssertEqual(stored.name, result.name)
    XCTAssertEqual(try ImageAttachmentStorage.data(stored, root: root), result.data)
  }

  func testAppshotFilenameSanitizesAppNameAndUsesUTCTimestamp() {
    let date = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(AppshotImage.filename(applicationName: " Xcode / Beta: Editor ", at: date),
      "Xcode - Beta- Editor Appshot 1970-01-01T00-00-00.000Z.png")
    XCTAssertEqual(AppshotImage.filename(applicationName: nil, at: date),
      "App Appshot 1970-01-01T00-00-00.000Z.png")
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
    let oldContext = Data(#"{"appName":"Sample","bundleIdentifier":"com.example.app","windowTitle":"Window","axTree":"AXWindow"}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(AppshotContext.self, from: oldContext).iconPNG)
  }

  func testCapturedAppIconPersistsWithAttachmentAndRejectsOversizedData() throws {
    let graphics = try XCTUnwrap(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    graphics.setFillColor(NSColor.systemRed.cgColor)
    graphics.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
    let icon = NSImage(cgImage: try XCTUnwrap(graphics.makeImage()), size: NSSize(width: 24, height: 24))
    let png = try XCTUnwrap(AppshotIcon.pngData(icon))
    XCTAssertLessThanOrEqual(png.count, AppshotIcon.maxBytes)
    let restored = try XCTUnwrap(AppshotIcon.image(png))
    XCTAssertEqual(restored.size, NSSize(width: 128, height: 128))
    XCTAssertNil(AppshotIcon.image(Data(repeating: 0, count: AppshotIcon.maxBytes + 1)))
    let metadata = AppshotContext(appName: "Sample", bundleIdentifier: nil,
      windowTitle: "Window", axTree: "", iconPNG: png)
    let attachment = ImageAttachment(id: UUID(), name: "shot.png", mimeType: "image/png",
      byteCount: 1, sha256: "digest", appshot: metadata)
    XCTAssertEqual(try JSONDecoder().decode(ImageAttachment.self,
      from: JSONEncoder().encode(attachment)).appshot?.iconPNG, png)
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
    XCTAssertEqual(metadata.displayTitle, "Main")
    XCTAssertEqual(AppshotContext(appName: "Sample", bundleIdentifier: nil,
      windowTitle: " ", axTree: "").displayTitle, "Sample")
    let result = AppshotCaptureResult(data: encoded.data, name: encoded.name, context: metadata)
    await store.captureAppshot(draft: "second", capture: { result })
    XCTAssertEqual(store.library.draftImages["second"]?.count, 1)
    XCTAssertEqual(store.library.draftImages["second"]?.first?.appshot, metadata)
    XCTAssertNil(store.library.draftImages["first"])
    await store.captureAppshot(draft: "first", capture: { nil })
    XCTAssertNil(store.library.draftImages["first"])
    XCTAssertFalse(store.importingImages)
    await store.shutdown()
  }
}
