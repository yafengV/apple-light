import Foundation

/// Keeps the exact Git diff used by a review outside the frequently rewritten workspace record.
enum ReviewSnapshotStorage {
  private static func location(runID: String, root: URL) throws -> URL {
    guard UUID(uuidString: runID) != nil else {
      throw AgentFailure(message: "审查记录标识无效。")
    }
    return root.appendingPathComponent("ReviewSnapshots", isDirectory: true)
      .appendingPathComponent(runID + ".json")
  }

  static func save(_ snapshot: ModelCodeReviewSnapshot, runID: String, root: URL) throws {
    guard snapshot.diff.utf8.count <= GitReviewService.modelReviewMaximumBytes else {
      throw AgentFailure(message: "审查差异超过允许大小。")
    }
    let url = try location(runID: runID, root: root)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "审查快照目录无效。")
    }
    if FileManager.default.fileExists(atPath: url.path),
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
      throw AgentFailure(message: "审查快照文件无效。")
    }
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func load(runID: String, root: URL) throws -> ModelCodeReviewSnapshot {
    let url = try location(runID: runID, root: root)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw AgentFailure(message: "原审查差异快照已不存在，无法按原内容重新运行。")
    }
    guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])
      .isSymbolicLink != true else {
      throw AgentFailure(message: "原审查差异快照目录无效。")
    }
    guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "原审查差异快照无效。")
    }
    let data = try Data(contentsOf: url)
    guard data.count <= 3_200_000 else {
      throw AgentFailure(message: "原审查差异快照超过允许大小。")
    }
    let snapshot = try JSONDecoder().decode(ModelCodeReviewSnapshot.self, from: data)
    guard snapshot.diff.utf8.count <= GitReviewService.modelReviewMaximumBytes else {
      throw AgentFailure(message: "原审查差异快照超过允许大小。")
    }
    return snapshot
  }

  static func remove(runID: String, root: URL) {
    guard let url = try? location(runID: runID, root: root) else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
