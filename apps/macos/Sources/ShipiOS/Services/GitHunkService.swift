import Foundation

enum GitHunkService {
  static func apply(
    _ action: GitHunkAction, path: String, hunkID: Int, snapshot: ReviewDiff, at root: URL
  ) async throws {
    _ = try LocalWorkspaceService.resolvedFile(path, root: root)
    let status = try await GitReviewService.checked(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], at: root)
    guard let file = GitFile.parse(status).first(where: { $0.path == path }), !file.untracked,
      action.scope == .staged ? file.staged : file.unstaged
    else {
      throw AgentFailure(message: "变更状态已改变，请刷新后重试。")
    }
    for path in file.comparisonPaths(scope: action.scope) {
      _ = try LocalWorkspaceService.resolvedFile(path, root: root)
    }
    let arguments = try await GitReviewService.arguments(
      scope: action.scope, selection: "", at: root)
    let current = try await GitReviewService.fileDiff(
      file, scope: action.scope, arguments: arguments, at: root)
    guard current.fingerprint == snapshot.fingerprint else {
      throw AgentFailure(message: "文件内容已改变，未应用旧差异。请刷新后重新选择差异块。")
    }
    let patch = try current.patch(for: hunkID, path: path)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shipios-hunk-" + UUID().uuidString + ".patch")
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: Data(patch.utf8), attributes: [.posixPermissions: 0o600])
    else {
      throw AgentFailure(message: "无法准备差异块。")
    }
    defer { try? FileManager.default.removeItem(at: temporary) }
    let apply = ["apply", "--whitespace=nowarn"] + action.arguments
    _ = try await GitReviewService.checked(apply + ["--check", "--", temporary.path], at: root)
    // No --reject, --3way, or whitespace rewriting: Git applies the selected patch or fails.
    _ = try await GitReviewService.checked(apply + ["--", temporary.path], at: root)
  }
}
