import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShipiOS

final class ImagePreviewSourceTests: XCTestCase {
  func testToolGalleryPreservesBlockOrderIncludingDuplicateImagesAndExcludesOtherContent() throws {
    let bytes = try AttachmentFixture.png().base64EncodedString()
    let document = MCPResultDocument.parse(JSONValue.object(["content": .array([
      .object(["type": .string("image"), "data": .string(bytes), "mimeType": .string("image/png")]),
      .object(["type": .string("text"), "text": .string("between images")]),
      .object(["type": .string("image"), "data": .string(bytes), "mimeType": .string("image/png")]),
      .object(["type": .string("audio"), "data": .string("AA=="), "mimeType": .string("audio/wav")]),
    ])]).pretty)
    XCTAssertEqual(document.previewImages.map(\.id), ["tool-image-0", "tool-image-2"])
    XCTAssertEqual(Set(document.previewImages.map(\.id)).count, 2)
    XCTAssertEqual(document.previewImages[1].name, "工具图片 3.png")
  }

  func testToolPreviewUsesNaturalPixelsAndExportRetainsExactOriginalBytes() throws {
    let data = try png(width: 5000, height: 2)
    let item = ImagePreviewItem(blockID: 2, base64: data.base64EncodedString(), mime: "IMAGE/PNG")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let image = try item.raster(root: root)
    XCTAssertEqual(image.width, 5000, "Full preview must not inherit the old 4096 px thumbnail cap")
    XCTAssertEqual(image.height, 2)
    XCTAssertEqual(try item.data(root: root), data)
    XCTAssertEqual(item.mimeType, "image/png")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Opening tool images must not import copies into attachment storage")
  }

  func testToolPreviewRejectsInvalidOrUnboundedRaster() throws {
    XCTAssertThrowsError(try MCPResultMedia.preview(base64: "invalid", mime: "image/png"))
    XCTAssertThrowsError(try MCPResultMedia.preview(base64: "AA==", mime: "image/svg+xml"))
    let oversized = try png(width: 20_001, height: 1)
    XCTAssertThrowsError(try MCPResultMedia.preview(base64: oversized.base64EncodedString(), mime: "image/png"))
  }

  @MainActor func testToolPreviewSnapshotDoesNotReplaceExistingOverlayOrAttachmentGroup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let attachment = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "history.png", root: root)
    let tool = ImagePreviewItem(blockID: 0, base64: try AttachmentFixture.png().base64EncodedString(), mime: "image/png")
    store.preview(attachment)
    store.preview(tool, images: [tool])
    XCTAssertEqual(store.previewImage, ImagePreviewItem(attachment))
    store.setOverlay(.imagePreview, presented: false)
    store.preview(tool, images: [tool])
    XCTAssertEqual(store.previewImage, tool)
    XCTAssertEqual(store.previewImages, [tool])
    XCTAssertFalse(store.commandEnabled("new"))
    store.setOverlay(.imagePreview, presented: false)
    store.setOverlay(.commands, presented: true)
    store.preview(tool, images: [tool])
    XCTAssertEqual(store.presentedOverlay, .commands)
    await store.shutdown()
  }

  private func png(width: Int, height: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return bytes as Data
  }
}
