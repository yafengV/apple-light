import Foundation

/// Preview the same selection for statistics and model context without changing the real index.
enum GitCommitIndex {
  static func withSelection<T>(at root: URL, includeUnstaged: Bool,
    operation: (URL?) async throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard includeUnstaged else { return try await operation(nil) }
    let conflicts = try await GitReviewService.checked(["ls-files", "--unmerged", "-z"], at: root)
    guard conflicts.isEmpty else { throw AgentFailure(message: "请先解决合并冲突，再预览提交内容。") }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-commit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let index = folder.appendingPathComponent("index")
    func checked(_ arguments: [String]) async throws {
      try Task.checkCancellation()
      let result = try await LocalWorkspaceService.git(["-c", "core.splitIndex=false"] + arguments,
        at: root, indexFile: index)
      guard result.status == 0 else { throw AgentFailure(message: result.text) }
    }
    let path = try await GitReviewService.checked(["rev-parse", "--git-path", "index"], at: root)
      .trimmingCharacters(in: .newlines)
    let original = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: original.path) {
      try FileManager.default.copyItem(at: original, to: index)
      // Preserve skip-worktree flags and expand a split index only in this temporary copy.
      try await checked(["update-index", "--no-split-index"])
    } else { try await checked(["read-tree", "--empty"]) }
    try await checked(["add", "--all", "--", "."])
    try Task.checkCancellation()
    return try await operation(index)
  }
}
