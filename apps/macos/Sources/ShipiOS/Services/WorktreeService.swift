import Foundation

enum WorktreeService {
  static func plan(snapshot: GitBranchSnapshot, branch: GitBranchChoice?, title: String, parent: URL) async throws -> PermanentWorktree {
    let current = try await GitBranchService.snapshot(at: snapshot.root)
    guard current.canChange else { throw AgentFailure(message: "请打开仓库根目录以创建工作树。") }
    let commit: String
    let name: String
    if let branch {
      guard current.branches.contains(where: { $0.reference == branch.reference && $0.commit == branch.commit }) else {
        throw AgentFailure(message: "起始分支已更新，请刷新后重试。")
      }
      commit = branch.commit; name = branch.name
    } else {
      guard let head = current.currentCommit, head == snapshot.currentCommit,
        current.currentReference == snapshot.currentReference else {
        throw AgentFailure(message: "当前提交已改变或仓库尚无提交，请刷新后重试。")
      }
      commit = head; name = current.currentName
    }
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw AgentFailure(message: "请填写工作树项目名称。") }
    let common = try await commonDirectory(at: current.root)
    let parent = GitBranchService.canonicalRoot(parent)
    guard parent.path != common.path, !parent.path.hasPrefix(common.path + "/") else {
      throw AgentFailure(message: "工作树目录不能位于 Git 元数据目录内。")
    }
    let id = UUID()
    return PermanentWorktree(id: id, source: current.root.path,
      path: parent.appendingPathComponent(id.uuidString, isDirectory: true).path,
      commonDirectory: common.path, startingCommit: commit, startingName: name,
      createdAt: Date(), title: String(title.prefix(120)))
  }

  /// Existing content is only registered if Git confirms it is this repository's worktree.
  /// No force removal, cleanup, branch reset, or source-file copy happens here.
  static func createOrRecover(_ record: PermanentWorktree) async throws {
    let source = URL(fileURLWithPath: record.source)
    let target = URL(fileURLWithPath: record.path)
    let common = try await commonDirectory(at: source)
    guard common.path == GitBranchService.canonicalRoot(URL(fileURLWithPath: record.commonDirectory)).path else {
      throw AgentFailure(message: "原项目的 Git 仓库已改变，无法恢复此工作树。")
    }
    let registered = try await registeredPaths(at: source)
    let targetPath = GitBranchService.canonicalRoot(target).path
    guard (try? FileManager.default.attributesOfItem(atPath: record.path)[.type]) as? FileAttributeType != .typeSymbolicLink else {
      throw AgentFailure(message: "目标目录已被符号链接替换，未修改该目录。")
    }
    if registered.contains(targetPath), FileManager.default.fileExists(atPath: record.path) {
      guard try await commonDirectory(at: target).path == common.path else {
        throw AgentFailure(message: "目标目录已被其他仓库替换，未修改该目录。")
      }
      _ = try await GitReviewService.checked(["rev-parse", "--verify", "HEAD^{commit}"], at: target)
      return
    }
    guard !FileManager.default.fileExists(atPath: record.path), !registered.contains(targetPath),
      (try? FileManager.default.attributesOfItem(atPath: record.path)) == nil else {
      throw AgentFailure(message: "目标目录或 Git 工作树记录已存在，请先在终端检查：\(record.path)")
    }
    // The setting might have been replaced with a symlink after the plan was saved.
    let parent = target.deletingLastPathComponent()
    guard GitBranchService.canonicalRoot(parent).path == parent.path,
      parent.path != common.path, !parent.path.hasPrefix(common.path + "/") else {
      throw AgentFailure(message: "工作树根目录已改变，请重新选择目录后创建。")
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = try await GitReviewService.checked(
      ["worktree", "add", "--detach", "--", target.path, record.startingCommit], at: source)
    let paths = try await registeredPaths(at: source)
    guard paths.contains(targetPath), try await commonDirectory(at: target).path == common.path else {
      throw AgentFailure(message: "工作树创建后校验未通过，请检查：\(record.path)")
    }
  }

  /// Only remove a managed checkout when no tracked, untracked, or ignored content would be lost.
  /// A protected HEAD ref must already exist before this call.
  static func removeCleanManaged(_ record: ManagedWorktree) async throws -> Bool {
    let source = URL(fileURLWithPath: record.source)
    let target = URL(fileURLWithPath: record.path)
    let targetPath = GitBranchService.canonicalRoot(target).path
    guard targetPath != GitBranchService.canonicalRoot(source).path,
      (try? FileManager.default.attributesOfItem(atPath: target.path)[.type]) as? FileAttributeType
        != .typeSymbolicLink else {
      throw AgentFailure(message: "托管工作树路径无效，未移除目录。")
    }
    let registered = try await registeredPaths(at: source)
    if !registered.contains(targetPath), !FileManager.default.fileExists(atPath: target.path) {
      return true
    }
    guard registered.contains(targetPath), FileManager.default.fileExists(atPath: target.path) else {
      throw AgentFailure(message: "托管工作树目录或 Git 登记已改变，未移除目录。")
    }
    let targetCommon = try await commonDirectory(at: target)
    let sourceCommon = try await commonDirectory(at: source)
    guard targetCommon.path == sourceCommon.path else {
      throw AgentFailure(message: "托管工作树目录或 Git 登记已改变，未移除目录。")
    }
    let status = try await GitReviewService.checked(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: target)
    let ignored = try await GitReviewService.checked(
      ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: target)
    guard status.isEmpty, ignored.isEmpty else { return false }
    _ = try await GitReviewService.checked(["worktree", "remove", "--", target.path], at: source)
    let remaining = try await registeredPaths(at: source)
    guard !FileManager.default.fileExists(atPath: target.path), !remaining.contains(targetPath) else {
      throw AgentFailure(message: "Git 工作树移除后校验失败，请在终端检查：\(record.path)")
    }
    return true
  }

  private static func registeredPaths(at source: URL) async throws -> Set<String> {
    let output = try await GitReviewService.checked(["worktree", "list", "--porcelain", "-z"], at: source)
    return Set(output.split(separator: "\0").filter { $0.hasPrefix("worktree ") }.map {
      GitBranchService.canonicalRoot(URL(fileURLWithPath: String($0.dropFirst(9)))).path
    })
  }

  private static func commonDirectory(at root: URL) async throws -> URL {
    let value = try await GitReviewService.checked(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
    let path = value.hasSuffix("\n") ? String(value.dropLast()) : value
    return GitBranchService.canonicalRoot(URL(fileURLWithPath: path))
  }
}
