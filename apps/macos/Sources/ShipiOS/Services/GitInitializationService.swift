import Darwin
import Foundation

enum GitInitializationService {
  private struct DirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  static func initialize(at project: URL, authorize: GitMutationAuthorization = {}) async throws {
    let root = GitBranchService.canonicalRoot(project)
    let identity = try directoryIdentity(at: root)
    try rejectExistingRepository(at: root)
    let bare = try await LocalWorkspaceService.git(["rev-parse", "--is-bare-repository"], at: root)
    guard bare.status != 0 || bare.text.trimmingCharacters(in: .whitespacesAndNewlines) != "true" else {
      throw AgentFailure(message: "此目录是裸 Git 仓库，请打开带工作区的项目。")
    }
    try await authorize()
    try Task.checkCancellation()
    guard GitBranchService.canonicalRoot(project) == root,
      try directoryIdentity(at: root) == identity else {
      throw AgentFailure(message: "项目目录已变化，请重新打开项目后重试。")
    }
    // Git commands intentionally stop discovery at the selected project's parent.
    // Inspect ancestors separately to avoid creating a nested repository there.
    try rejectExistingRepository(at: root)
    _ = try await GitReviewService.checked(["init", "--quiet", "--", root.path], at: root)
  }

  private static func directoryIdentity(at root: URL) throws -> DirectoryIdentity {
    var info = stat()
    guard stat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw AgentFailure(message: "项目目录不可用，请重新打开有效的文件夹。")
    }
    return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
  }

  private static func rejectExistingRepository(at root: URL) throws {
    var directory = root
    while true {
      var info = stat()
      let result = lstat(directory.appendingPathComponent(".git").path, &info)
      if result == 0 {
        if directory == root {
          throw AgentFailure(message: "项目已有 Git 元数据，请刷新审查；如果仍无法读取，请检查仓库状态。")
        }
        throw AgentFailure(message: "项目位于已有 Git 仓库中，请打开仓库根目录：\(directory.path)")
      }
      guard errno == ENOENT else {
        throw AgentFailure(message: "无法检查项目的 Git 元数据，请确认目录可访问后重试。")
      }
      let parent = directory.deletingLastPathComponent()
      if parent == directory { return }
      directory = parent
    }
  }
}
