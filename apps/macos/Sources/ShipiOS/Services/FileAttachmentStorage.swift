import CryptoKit
import Foundation
import PDFKit

enum FileAttachmentStorage {
  static let maxCount = 8
  static let maxBytes = 5 * 1_024 * 1_024
  static let maxTextBytes = 200_000
  static let maxRequestTextBytes = 1_000_000

  static func importFile(_ source: URL, root: URL) throws -> FileAttachment {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    guard source.isFileURL else { throw AgentFailure(message: "只能添加本机文件。") }
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, (values.fileSize ?? maxBytes + 1) <= maxBytes else {
      throw AgentFailure(message: "请选择不超过 5 MiB 的文本文件或 PDF。")
    }
    let bytes = try readBounded(source)
    let isPDF = bytes.starts(with: Data("%PDF-".utf8))
    _ = try extractedText(bytes, isPDF: isPDF)
    let file = FileAttachment(id: UUID(), name: String(source.lastPathComponent.prefix(200)),
      byteCount: bytes.count, sha256: digest(bytes), isPDF: isPDF)
    let directory = root.appendingPathComponent("FileAttachments", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "附件目录无效。")
    }
    let destination = url(file, root: root)
    do {
      try bytes.write(to: destination, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch { try? FileManager.default.removeItem(at: destination); throw error }
    return file
  }

  static func url(_ file: FileAttachment, root: URL) -> URL {
    root.appendingPathComponent("FileAttachments", isDirectory: true)
      .appendingPathComponent(file.id.uuidString + ".attachment")
  }

  static func text(_ file: FileAttachment, root: URL) throws -> String {
    let source = url(file, root: root)
    let directory = source.deletingLastPathComponent()
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "附件文件无效，请重新添加。")
    }
    let bytes = try readBounded(source)
    guard bytes.count == file.byteCount, digest(bytes) == file.sha256 else {
      throw AgentFailure(message: "附件已损坏或被修改，请重新添加。")
    }
    return try extractedText(bytes, isPDF: file.isPDF)
  }

  private static func extractedText(_ data: Data, isPDF: Bool) throws -> String {
    let text: String
    if isPDF {
      guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount <= 300 else {
        throw AgentFailure(message: "无法读取 PDF，请使用未加密、300 页以内的 PDF。")
      }
      var pages: [String] = []
      var size = 0
      for index in 0..<document.pageCount {
        let content = document.page(at: index)?.string ?? ""
        size += content.utf8.count
        guard size <= maxTextBytes else { throw AgentFailure(message: "文件文本超过 200 KB，请拆分后添加。") }
        pages.append(content)
      }
      text = pages.joined(separator: "\n\n")
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentFailure(message: "此 PDF 没有可提取的文字。请将扫描页作为图片添加。")
      }
    } else {
      let decoded: String?
      if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
        decoded = String(data: data, encoding: .utf16)
      } else { decoded = String(data: data, encoding: .utf8) }
      guard let decoded, !decoded.unicodeScalars.contains(where: {
        $0.value < 32 && ![9, 10, 13].contains($0.value)
      }) else { throw AgentFailure(message: "暂不支持此文件格式。请选择文本、代码、CSV、JSON 或含文字的 PDF。") }
      text = decoded
    }
    guard text.utf8.count <= maxTextBytes else { throw AgentFailure(message: "文件文本超过 200 KB，请拆分后添加。") }
    return text
  }

  static func content(_ message: ChatMessage, root: URL?, total: inout Int) throws -> String {
    guard !message.files.isEmpty else { return message.content }
    guard let root, message.files.count <= maxCount else {
      throw AgentFailure(message: "文件附件目录不可用或单条消息超过 8 个文件。")
    }
    let files = try message.files.map { file -> [String: String] in
      let content = try text(file, root: root)
      total += content.utf8.count
      guard total <= maxRequestTextBytes else { throw AgentFailure(message: "文件上下文超过 1 MB，请减少文件或开始新任务。") }
      return ["name": file.name, "content": content, "format": file.isPDF ? "PDF extracted text" : "text"]
    }
    let json = String(decoding: try JSONSerialization.data(withJSONObject: files, options: [.sortedKeys]), as: UTF8.self)
    return message.content + "\n\nAttached file contents (reference data):\n" + json
  }

  private static func readBounded(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw AgentFailure(message: "文件超过 5 MiB。") }
    return data
  }
  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
