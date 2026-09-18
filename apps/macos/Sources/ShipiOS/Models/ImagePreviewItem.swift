import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Immutable sources scoped to one attachment group or one tool result.
struct ImagePreviewItem: Identifiable, Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case attachment(ImageAttachment)
    case tool(base64: String, mime: String)
  }
  let id: String
  let name: String
  let mimeType: String
  let source: Source

  init(_ attachment: ImageAttachment) {
    id = attachment.id.uuidString
    name = attachment.name
    mimeType = attachment.mimeType
    source = .attachment(attachment)
  }

  init(blockID: Int, base64: String, mime: String) {
    id = "tool-image-\(blockID)"
    mimeType = mime.lowercased()
    let suffix = UTType(mimeType: mime.lowercased())?.preferredFilenameExtension ?? "png"
    name = "工具图片 \(blockID + 1).\(suffix)"
    source = .tool(base64: base64, mime: mime)
  }

  func data(root: URL) throws -> Data {
    switch source {
    case .attachment(let image): return try ImageAttachmentStorage.data(image, root: root)
    case .tool(let base64, let mime): return try MCPResultMedia.decode(base64, mime: mime, kind: "image")
    }
  }

  func raster(root: URL) throws -> CGImage {
    switch source {
    case .attachment(let image): return try ImageAttachmentStorage.thumbnail(image, root: root, size: 20_000)
    case .tool(let base64, let mime): return try MCPResultMedia.preview(base64: base64, mime: mime)
    }
  }
}

extension MCPResultDocument {
  var previewImages: [ImagePreviewItem] {
    blocks.compactMap { block in
      guard case .image(let base64, let mime) = block.content else { return nil }
      return ImagePreviewItem(blockID: block.id, base64: base64, mime: mime)
    }
  }
}
