import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageAttachmentStorage {
  static let maxCount = 8
  static let maxBytes = 10 * 1_024 * 1_024
  static let maxRequestBytes = 32 * 1_024 * 1_024

  static func importFile(_ source: URL, root: URL) throws -> ImageAttachment {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    guard source.isFileURL else { throw AgentFailure(message: "只能添加本机图片文件。") }
    let properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true, (properties.fileSize ?? maxBytes + 1) <= maxBytes else {
      throw AgentFailure(message: "请选择不超过 10 MiB 的图片文件。")
    }
    return try importData(readBounded(source), name: source.lastPathComponent, root: root)
  }

  static func importData(_ data: Data, name: String, root: URL) throws -> ImageAttachment {
    guard !data.isEmpty, data.count <= maxBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let type = CGImageSourceGetType(source) as String?,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 20_000, height <= 20_000,
      width * height <= 40_000_000
    else { throw AgentFailure(message: "无法读取图片，请使用 10 MiB、4000 万像素以内的静态图片。") }
    let mime: String
    let stored: Data
    switch type {
    case UTType.png.identifier:
      mime = "image/png"
      stored = data
    case UTType.jpeg.identifier:
      mime = "image/jpeg"
      stored = data
    case UTType.webP.identifier:
      mime = "image/webp"
      stored = data
    case UTType.gif.identifier:
      mime = "image/gif"
      stored = data
    case UTType.tiff.identifier:
      // macOS screenshots on the pasteboard commonly use TIFF.
      let output = NSMutableData()
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary),
        let destination = CGImageDestinationCreateWithData(
          output, UTType.png.identifier as CFString, 1, nil)
      else { throw AgentFailure(message: "无法转换剪贴板图片。") }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination), output.length <= maxBytes else {
        throw AgentFailure(message: "转换后的图片超过 10 MiB。")
      }
      mime = "image/png"
      stored = output as Data
    default: throw AgentFailure(message: "支持 PNG、JPEG、WebP 和静态 GIF 图片。")
    }
    let attachment = ImageAttachment(
      id: UUID(), name: String(name.prefix(200)), mimeType: mime,
      byteCount: stored.count, sha256: digest(stored))
    let directory = root.appendingPathComponent("Attachments", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = url(attachment, root: root)
    do {
      try stored.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    return attachment
  }

  static func url(_ image: ImageAttachment, root: URL) -> URL {
    root.appendingPathComponent("Attachments", isDirectory: true)
      .appendingPathComponent(image.id.uuidString + "." + image.fileExtension)
  }
  static func data(_ image: ImageAttachment, root: URL) throws -> Data {
    let file = url(image, root: root)
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AgentFailure(message: "附件文件无效，请重新添加图片。")
    }
    let data = try readBounded(file)
    guard data.count == image.byteCount, digest(data) == image.sha256 else {
      throw AgentFailure(message: "附件已损坏或被修改，请重新添加图片。")
    }
    return data
  }
  static func thumbnail(_ image: ImageAttachment, root: URL, size: Int) throws -> CGImage {
    let data = try data(image, root: root)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary)
    else { throw AgentFailure(message: "无法预览此图片。") }
    return thumbnail
  }

  static func requestData(config: ModelConfiguration, messages: [ChatMessage], root: URL?, tools: [JSONValue] = []) throws
    -> Data
  {
    var total = 0
    var textTotal = 0
    let wire: [[String: Any]] = try messages.map { message in
      let content = try FileAttachmentStorage.content(message, root: root, total: &textTotal)
      guard !message.images.isEmpty else {
        var value: [String: Any] = ["role": message.role, "content": content]
        if !message.toolCalls.isEmpty {
          value["tool_calls"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message.toolCalls.map(\.wire)))
        }
        if let id = message.toolCallID { value["tool_call_id"] = id }
        return value
      }
      guard let root else { throw AgentFailure(message: "未提供图片附件目录。") }
      guard message.images.count <= maxCount else { throw AgentFailure(message: "每条消息最多添加 8 张图片。") }
      var parts: [[String: Any]] = []
      if !content.isEmpty { parts.append(["type": "text", "text": content]) }
      for image in message.images {
        guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(image.mimeType),
          image.byteCount > 0, image.byteCount <= maxBytes,
          total <= maxRequestBytes - image.byteCount
        else {
          throw AgentFailure(message: "图片上下文超过 32 MiB 或格式无效，请减少图片或开始新任务。")
        }
        total += image.byteCount
        let bytes = try data(image, root: root)
        parts.append([
          "type": "image_url",
          "image_url": ["url": "data:\(image.mimeType);base64,\(bytes.base64EncodedString())"],
        ])
      }
      return ["role": message.role, "content": parts]
    }
    var body: [String: Any] = ["model": config.model, "stream": true, "messages": wire]
    if !tools.isEmpty {
      body["tools"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools))
    }
    if !config.reasoning.isEmpty { body["reasoning_effort"] = config.reasoning }
    if config.includeUsage { body["stream_options"] = ["include_usage": true] }
    return try JSONSerialization.data(withJSONObject: body)
  }

  private static func readBounded(_ url: URL) throws -> Data {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let data = try file.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw AgentFailure(message: "图片超过 10 MiB。") }
    return data
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
