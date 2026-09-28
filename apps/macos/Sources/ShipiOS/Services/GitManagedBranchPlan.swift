import Foundation

struct GitSyncedBranch: Codable, Equatable {
  let reference: String
  let tree: String
}

struct GitManagedBranchPlan {
  let snapshot: GitBranchSnapshot
  let name: String
  let tree: String

  static func normalizedName(_ input: String) throws -> String {
    var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("refs/heads/") { name = String(name.dropFirst("refs/heads/".count)) }
    guard !name.isEmpty, !name.hasPrefix("-"), !name.hasSuffix("/"),
      !["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: { name.hasPrefix($0) }) else {
      throw AgentFailure(message: "请填写有效的本地分支名称。")
    }
    return name
  }
  static func validate(_ input: String, at root: URL) async throws -> String {
    let name = try normalizedName(input)
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "--branch", name], at: root)
    guard valid.status == 0, valid.text.trimmingCharacters(in: .newlines) == name else {
      throw AgentFailure(message: "分支名称无效。")
    }
    let exists = try await LocalWorkspaceService.git(["show-ref", "--verify", "--quiet", "refs/heads/" + name], at: root)
    guard exists.status == 1 else {
      throw AgentFailure(message: exists.status == 0 ? "此分支已存在。" : "无法检查分支，请重新读取仓库。")
    }
    return name
  }
  static func capture(_ input: String, snapshot: GitBranchSnapshot) async throws -> Self {
    let name = try await validate(input, at: snapshot.root)
    let current = try await GitBranchService.snapshot(at: snapshot.root)
    guard current.canChange, current.currentCommit == snapshot.currentCommit,
      current.currentReference == snapshot.currentReference, let commit = current.currentCommit else {
      throw AgentFailure(message: "来源分支或提交已改变，请重新检查。")
    }
    let tree = try await GitReviewService.checked(["rev-parse", commit + "^{tree}"], at: current.root)
      .trimmingCharacters(in: .newlines)
    return Self(snapshot: current, name: name, tree: tree)
  }
  func create(authorize: GitMutationAuthorization) async throws {
    _ = try await Self.capture(name, snapshot: snapshot)
    guard let commit = snapshot.currentCommit else { throw AgentFailure(message: "来源尚无提交。") }
    try await authorize()
    _ = try await GitReviewService.checked(["branch", "--", name, commit], at: snapshot.root)
  }
  func checkout(authorize: GitMutationAuthorization) async throws {
    let current = try await GitBranchService.snapshot(at: snapshot.root)
    guard current.currentCommit == snapshot.currentCommit, current.currentReference == snapshot.currentReference,
      current.branches.contains(where: { $0.reference == "refs/heads/" + name && $0.commit == snapshot.currentCommit }) else {
      throw AgentFailure(message: "来源或新分支已改变，未继续检出。")
    }
    try await authorize()
    _ = try await GitReviewService.checked(["switch", "--no-guess", "--no-overwrite-ignore", "--", name], at: snapshot.root)
  }
}
