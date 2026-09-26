import CryptoKit
import Foundation

/// Exact per-turn diff snapshots live outside frequently rewritten workspace.json.
enum CodexTurnDiffStorage {
  private static func location(id: UUID, root: URL) -> URL {
    root.appendingPathComponent("CodexTurnDiffs", isDirectory: true)
      .appendingPathComponent(id.uuidString + ".patch")
  }

  static func save(_ source: String, id: UUID, root: URL) throws -> (byteCount: Int, sha256: String) {
    let url = location(id: id, root: root)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "代码差异快照目录无效。")
    }
    if FileManager.default.fileExists(atPath: url.path),
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      throw AgentFailure(message: "代码差异快照路径无效。")
    }
    let data = Data(source.utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return (data.count, digest)
  }

  static func load(_ diff: CodexTurnDiff, root: URL) throws -> String {
    guard let expectedSize = diff.storedByteCount, let expectedHash = diff.contentSHA256 else {
      guard !diff.truncated else {
        throw AgentFailure(message: "旧任务只保存了差异预览，完整快照不可用。")
      }
      return diff.unifiedDiff
    }
    let url = location(id: diff.id, root: root)
    guard FileManager.default.fileExists(atPath: url.path),
      try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])
        .isSymbolicLink != true,
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "本轮完整代码差异快照已不存在。")
    }
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard data.count == expectedSize, digest == expectedHash,
      let source = String(data: data, encoding: .utf8) else {
      throw AgentFailure(message: "本轮代码差异快照校验失败。")
    }
    return source
  }

  static func remove(id: UUID, root: URL) {
    try? FileManager.default.removeItem(at: location(id: id, root: root))
  }
}
