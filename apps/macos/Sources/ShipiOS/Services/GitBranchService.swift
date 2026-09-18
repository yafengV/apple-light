import Foundation
import Darwin

enum GitBranchService {
  static func canonicalRoot(_ url: URL) -> URL {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path, let resolved = realpath(path, nil) else {
        // Resolve the existing ancestor before appending a not-yet-created path.
        // Foundation standardization can shorten /private/tmp only once it exists.
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url }
        return canonicalRoot(parent).appendingPathComponent(url.lastPathComponent)
      }
      defer { free(resolved) }
      return URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
    }
  }

  static func snapshot(at root: URL) async throws -> GitBranchSnapshot {
    let root = canonicalRoot(root)
    let output = try await GitReviewService.checked(["rev-parse", "--show-toplevel"], at: root)
    let path = output.hasSuffix("\n") ? String(output.dropLast()) : output
    let repository = canonicalRoot(URL(fileURLWithPath: path))
    let head = try await LocalWorkspaceService.git(["symbolic-ref", "-q", "HEAD"], at: root)
    let commit = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD^{commit}"], at: root)
    let refs = try await GitReviewService.checked([
      "for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)",
      "refs/heads", "refs/remotes",
    ], at: root)
    let worktrees = try await GitReviewService.checked(["worktree", "list", "--porcelain", "-z"], at: root)
    let occupied = worktreeBranches(worktrees)
    let branches = refs.split(separator: "\n").compactMap { line -> GitBranchChoice? in
      let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
      guard fields.count == 3, fields[2].isEmpty else { return nil }
      let ref = String(fields[0])
      return GitBranchChoice(reference: ref, commit: String(fields[1]), checkedOutPath: occupied[ref])
    }
    let status = try await GitReviewService.checked(
      ["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root)
    return GitBranchSnapshot(root: root, repositoryRoot: repository,
      currentReference: head.status == 0 ? head.text.trimmingCharacters(in: .newlines) : nil,
      currentCommit: commit.status == 0 ? commit.text.trimmingCharacters(in: .newlines) : nil,
      branches: branches, changedFiles: GitFile.parse(status).count)
  }

  static func apply(_ change: GitBranchChange, snapshot previous: GitBranchSnapshot) async throws {
    let current = try await snapshot(at: previous.root)
    guard current.canChange else {
      throw AgentFailure(message: "请先打开仓库根目录，再切换分支：\(current.repositoryRoot.path)")
    }
    guard current.currentReference == previous.currentReference,
      current.currentCommit == previous.currentCommit else {
      throw AgentFailure(message: "当前分支或提交已发生变化，请刷新列表后重试。")
    }
    let args: [String]
    switch change {
    case .switchTo(let chosen):
      let branch = try validate(chosen, in: current)
      guard !branch.isRemote else { throw AgentFailure(message: "请选择用于跟踪远程分支的本地分支名称。") }
      guard !current.isOccupied(branch) else { throw AgentFailure(message: "此分支已由另一个工作树使用。") }
      if branch.reference == current.currentReference { return }
      args = ["switch", "--no-guess", "--no-overwrite-ignore", "--", branch.name]
    case .create(let rawName, let startingAt):
      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      let check = try await LocalWorkspaceService.git(["check-ref-format", "--branch", name], at: current.root)
      guard check.status == 0, check.text.trimmingCharacters(in: .newlines) == name,
        !name.isEmpty, !name.hasPrefix("-") else {
        throw AgentFailure(message: "分支名称无效，请使用 Git 支持的分支名称。")
      }
      guard !current.branches.contains(where: { $0.reference == "refs/heads/" + name }) else {
        throw AgentFailure(message: "该本地分支已存在，请选择现有分支或使用其他名称。")
      }
      if let startingAt {
        let branch = try validate(startingAt, in: current)
        args = ["switch", "--no-overwrite-ignore", "-c", name]
          + (branch.isRemote ? ["--track", branch.reference] : ["--no-track", branch.commit])
      } else {
        guard let commit = current.currentCommit else {
          throw AgentFailure(message: "仓库还没有提交，请先完成首次提交。")
        }
        args = ["switch", "--no-overwrite-ignore", "--no-track", "-c", name, commit]
      }
    }
    _ = try await GitReviewService.checked(args, at: current.root)
  }

  private static func validate(_ chosen: GitBranchChoice, in snapshot: GitBranchSnapshot) throws -> GitBranchChoice {
    guard let current = snapshot.branches.first(where: { $0.reference == chosen.reference }),
      current.commit == chosen.commit else {
      throw AgentFailure(message: "目标分支已更新或被删除，请刷新列表后重试。")
    }
    return current
  }

  static func worktreeBranches(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    var path: String?
    for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
      if field.isEmpty { path = nil }
      else if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
      else if field.hasPrefix("branch "), let path { result[String(field.dropFirst(7))] = path }
    }
    return result
  }
}
