import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class ImagePreviewTests: XCTestCase {
  func testFitNeverUpscalesAndRampIncludesSmallFitWithBoundedSteps() {
    var zoom = ImagePreviewZoom(naturalSize: CGSize(width: 4000, height: 2000), viewport: CGSize(width: 600, height: 400))
    XCTAssertEqual(zoom.percent, 15)
    XCTAssertEqual(zoom.minimum, 15)
    XCTAssertEqual(zoom.step(1), 25)
    zoom.requestedPercent = 100
    XCTAssertEqual(zoom.step(-1), 90)
    XCTAssertEqual(zoom.step(1), 110)
    zoom.requestedPercent = 999
    XCTAssertEqual(zoom.percent, 500)
    zoom.requestedPercent = -.infinity
    XCTAssertEqual(zoom.percent, 15)
    zoom.naturalSize = CGSize(width: 200, height: 100)
    zoom.requestedPercent = nil
    XCTAssertEqual(zoom.percent, 100)
    XCTAssertEqual(zoom.imageRect.origin, CGPoint(x: 200, y: 150))
  }

  func testZoomRetainsPointUnderCursorAndClampsPanningToImageBounds() {
    let before = ImagePreviewZoom(naturalSize: CGSize(width: 1200, height: 800), viewport: CGSize(width: 600, height: 400))
    var after = before
    after.requestedPercent = 100
    XCTAssertEqual(after.offset(from: before, oldOffset: .zero, anchor: CGPoint(x: 300, y: 200)),
      CGPoint(x: 300, y: 200))
    XCTAssertEqual(after.offset(from: before, oldOffset: .zero, anchor: CGPoint(x: 100, y: 100)),
      CGPoint(x: 100, y: 100))
    XCTAssertEqual(after.clampedOffset(CGPoint(x: -50, y: 900)), CGPoint(x: 0, y: 400))
    after.requestedPercent = nil
    XCTAssertEqual(after.clampedOffset(CGPoint(x: 900, y: 900)), .zero)
  }

  @MainActor func testPreviewKeyboardRoutesGalleryZoomAndCloseWithoutCommandCollision() throws {
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> ImagePreviewKeyboardBridge.Key? {
      ImagePreviewKeyboardBridge.key(for: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
    }
    XCTAssertEqual(try key("=", code: 24, modifiers: .command), .zoomIn)
    XCTAssertEqual(try key("+", code: 24, modifiers: [.command, .shift]), .zoomIn)
    XCTAssertEqual(try key("-", code: 27, modifiers: .command), .zoomOut)
    XCTAssertEqual(try key("0", code: 29, modifiers: .command), .fit)
    XCTAssertEqual(try key("w", code: 13, modifiers: .command), .close)
    XCTAssertEqual(try key("", code: 53), .close)
    XCTAssertEqual(try key("", code: 123), .previous)
    XCTAssertEqual(try key("", code: 124), .next)
    XCTAssertEqual(try key("\t", code: 48, modifiers: .shift), .tab(true))
    XCTAssertNil(try key("w", code: 13, modifiers: [.command, .shift]))
    XCTAssertNil(try key("", code: 124, modifiers: .option))
    XCTAssertNil(try key("0", code: 29))
  }

  @MainActor func testGalleryCapturesClickedGroupAndBlocksWorkspaceCommandsUntilDismissed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let first = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "first.png", root: root)
    let second = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "second.png", root: root)
    store.preview(second, images: [first, second])
    XCTAssertEqual(store.previewImage, ImagePreviewItem(second))
    XCTAssertEqual(store.previewImages, [first, second].map(ImagePreviewItem.init))
    XCTAssertEqual(store.presentedOverlay, .imagePreview)
    XCTAssertFalse(store.commandEnabled("settings"))
    XCTAssertFalse(store.commandEnabled("new"))
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌘N")))
    let oldFocus = store.focusComposer
    store.setOverlay(.imagePreview, presented: false)
    store.restoreOverlayFocus()
    XCTAssertNotEqual(store.focusComposer, oldFocus)
    XCTAssertTrue(store.commandEnabled("settings"))
    store.preview(first, images: [second])
    XCTAssertEqual(store.previewImages, [ImagePreviewItem(first)])
  }

  @MainActor func testNativeCanvasZoomPanResizeAndTeardown() async throws {
    _ = NSApplication.shared
    let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
      bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    var updates: [ImagePreviewZoom] = []
    let host = NSHostingView(rootView: ImagePreviewCanvas(image: image, requestedPercent: nil,
      onChange: { updates.append($0) }, onDismiss: {}))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func find(_ view: NSView) -> ImagePreviewCanvas.Canvas? {
      (view as? ImagePreviewCanvas.Canvas) ?? view.subviews.lazy.compactMap(find).first
    }
    let canvas = try XCTUnwrap(find(host))
    XCTAssertEqual(canvas.zoom.percent, 50, accuracy: 1)
    canvas.setZoom(100)
    XCTAssertEqual(canvas.contentView.bounds.origin.x, 300, accuracy: 1)
    XCTAssertEqual(canvas.contentView.bounds.origin.y, 200, accuracy: 1)
    canvas.pan(to: CGPoint(x: 40000, y: -100))
    XCTAssertEqual(canvas.contentView.bounds.origin.x, 600, accuracy: 1)
    XCTAssertEqual(canvas.contentView.bounds.origin.y, 0, accuracy: 1)
    canvas.update(image: image, requested: nil)
    XCTAssertEqual(canvas.contentView.bounds.origin, .zero)
    window.setContentSize(CGSize(width: 300, height: 200))
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(canvas.zoom.percent, 25, accuracy: 1)
    canvas.setZoom(100)
    ImagePreviewCanvas.dismantleNSView(canvas, coordinator: ())
    let count = updates.count
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(updates.count, count, "Dismantled canvases cannot publish late zoom values")
    XCTAssertFalse(canvas.acceptsFirstResponder)
  }
}
