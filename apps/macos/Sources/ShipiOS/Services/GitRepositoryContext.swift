import Darwin
import Foundation

enum GitRepositoryContext {
  /// Look for the nearest repository boundary without changing the command
  /// runner's discovery limit for file tools and task execution.
  static func candidate(at project: URL) throws -> URL? {
    var directory = GitBranchService.canonicalRoot(project)
    var selected = stat()
    guard stat(directory.path, &selected) == 0,
      selected.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw AgentFailure(message: "项目目录不可用，请重新打开有效的文件夹。")
    }
    while true {
      var info = stat()
      if lstat(directory.appendingPathComponent(".git").path, &info) == 0 { return directory }
      guard errno == ENOENT else {
        throw AgentFailure(message: "无法检查项目所属的 Git 仓库，请确认目录可访问。")
      }
      let parent = directory.deletingLastPathComponent()
      if parent == directory { return nil }
      directory = parent
    }
  }

  static func resolve(at project: URL) async throws -> URL? {
    guard let candidate = try candidate(at: project) else { return nil }
    let output = try await GitReviewService.checked(["rev-parse", "--show-toplevel"], at: candidate)
    let path = output.hasSuffix("\n") ? String(output.dropLast()) : output
    let root = GitBranchService.canonicalRoot(URL(fileURLWithPath: path))
    let selected = GitBranchService.canonicalRoot(project)
    guard root.path == candidate.path,
      selected.path == root.path || selected.path.hasPrefix(root.path + "/") else {
      throw AgentFailure(message: "Git 仓库与当前项目不匹配，请重新打开项目。")
    }
    return root
  }
}
