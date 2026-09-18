import Foundation

struct GitCommitSelection {
  let branch: GitBranchSnapshot
  let changes: GitBatchSnapshot
  let newBranch: String?

  static func capture(at root: URL, includeUnstaged: Bool, newBranch: String?) async throws -> Self {
    let branch = try await GitBranchService.snapshot(at: root)
    guard branch.canChange else { throw AgentFailure(message: "请打开仓库根目录后提交。") }
    if let newBranch { try await validateBranch(newBranch, at: root) }
    let changes = try await GitBatchService.capture(scope: includeUnstaged ? .unstaged : .staged, at: root)
    guard !changes.files.contains(where: \.conflicted) else {
      throw AgentFailure(message: "请先解决合并冲突，再提交变更。")
    }
    guard changes.files.contains(where: { $0.staged || (includeUnstaged && $0.unstaged) }) else {
      throw AgentFailure(message: "没有选中的变更可提交。")
    }
    return Self(branch: branch, changes: changes, newBranch: newBranch)
  }

  static func validateBranch(_ name: String, at root: URL) async throws {
    let checked = try await LocalWorkspaceService.git(["check-ref-format", "--branch", name], at: root)
    guard checked.status == 0, checked.text.trimmingCharacters(in: .newlines) == name,
      !name.hasPrefix("-"), !name.isEmpty else { throw AgentFailure(message: "新分支名称无效。") }
    let existing = try await LocalWorkspaceService.git(["show-ref", "--verify", "--quiet", "refs/heads/" + name], at: root)
    guard existing.status != 0 else { throw AgentFailure(message: "该本地分支已存在，请更换名称或选择当前分支。") }
  }

  func apply() async throws {
    let currentBranch = try await GitBranchService.snapshot(at: branch.root)
    let currentChanges = try await GitBatchService.capture(scope: changes.scope, at: changes.root)
    guard currentBranch.currentReference == branch.currentReference,
      currentBranch.currentCommit == branch.currentCommit,
      currentChanges.signature == changes.signature else {
      throw AgentFailure(message: "选中的变更或分支已改变，请刷新后重新提交。")
    }
    try Task.checkCancellation()
    if let newBranch {
      try await Self.validateBranch(newBranch, at: branch.root)
      if branch.currentCommit == nil {
        _ = try await GitReviewService.checked(["switch", "--no-track", "-c", newBranch], at: branch.root)
      } else {
        try await GitBranchService.apply(.create(name: newBranch, startingAt: nil), snapshot: branch)
      }
    }
    if changes.scope == .unstaged { try await GitBatchService.apply(changes) }
  }
}
