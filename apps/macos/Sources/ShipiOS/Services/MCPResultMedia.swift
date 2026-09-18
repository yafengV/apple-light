import Foundation
import ImageIO

enum MCPResultMedia {
  static let maxBytes = 8 * 1_048_576

  static func decode(_ base64: String, mime: String, kind: String) throws -> Data {
    let mime = mime.lowercased()
    let allowedImages = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/tiff", "image/heic"]
    guard kind == "image" ? allowedImages.contains(mime) : mime.hasPrefix("audio/") else {
      throw AgentFailure(message: "此媒体格式暂不支持预览，可查看原始输出。")
    }
    guard base64.utf8.count <= ((maxBytes + 2) / 3) * 4,
      let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= maxBytes else {
      throw AgentFailure(message: "媒体数据无效或超过 8 MiB，无法预览。")
    }
    return data
  }

  static func thumbnail(base64: String, mime: String, size: Int) throws -> CGImage {
    let data = try decode(base64, mime: mime, kind: "image")
    guard let source = CGImageSourceCreateWithData(data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, min(size, 4096)),
      ] as CFDictionary) else { throw AgentFailure(message: "无法解码工具返回的图片。") }
    return image
  }
}
