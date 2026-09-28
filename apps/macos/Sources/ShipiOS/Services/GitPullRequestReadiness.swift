import Foundation

/// Hosting checks belong to the entry, not to the editable PR form.
struct GitPullRequestReadiness: Equatable, Sendable {
  let context: GitHubPRContext
  let hasLocalChanges: Bool
  let hasConflicts: Bool
  let commitsAhead: Int
  var targetBranch: String? = nil

  func requiresRefresh(comparedTo previous: GitHubPRContext) -> Bool {
    context.plan != previous.plan || context.repository != previous.repository
      || context.defaultBranch != previous.defaultBranch || context.publishedCommit != previous.publishedCommit
      || context.existing?.url != previous.existing?.url
  }

  func blockedReason(includeLocalChanges: Bool, expectedContext: GitHubPRContext? = nil) -> String? {
    if let expectedContext, requiresRefresh(comparedTo: expectedContext) {
      return "PR 来源或状态已改变，请重新检查。"
    }
    if context.existing != nil { return "此分支已有 PR。" }
    if let problem = context.creationProblem { return problem }
    if !context.requiresNewBranch && targetBranch == context.head {
      return "请选择有效且不同于源分支的目标分支。"
    }
    if includeLocalChanges && hasConflicts { return "请先解决合并冲突，再提交变更。" }
    if context.requiresNewBranch {
      if commitsAhead == 0 && (!includeLocalChanges || !hasLocalChanges) {
        return "源提交没有相对目标分支的新提交，请包含本地变更后再创建 PR。"
      }
    } else if !includeLocalChanges && context.publishedCommit == nil {
      return "此分支尚未发布，请勾选提交并推送，或先推送分支。"
    }
    return nil
  }

  static func capture(at root: URL, base: String? = nil,
    service: GitHubPRService = GitHubPRService()) async throws -> Self {
    let context = try await service.inspect(at: root, allowUnpublished: true)
    // Viewing an existing PR does not need a valid commit selection or a readable base object.
    if context.existing != nil {
      guard try await GitPushService.prepare(at: root, remote: context.plan.remote,
        destination: context.head, forceWithLease: false) == context.plan else {
        throw GitHubPRRefreshRequired(message: "分支或远端已改变，请重新检查 PR。")
      }
      try Task.checkCancellation()
      return Self(context: context, hasLocalChanges: false, hasConflicts: false, commitsAhead: 0)
    }
    let changes = try await GitBatchService.capture(scope: .unstaged, at: root)
    let conflicts = changes.files.contains(where: \.conflicted)
    let hasChanges: Bool
    if conflicts { hasChanges = true }
    else { hasChanges = try await GitCommitSummary.capture(at: root, includeUnstaged: true).hasChanges }
    let target = base ?? context.defaultBranch
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + target], at: root)
    guard valid.status == 0 else { throw AgentFailure(message: "请选择有效的目标分支。") }
    let baseCommit = try await service.remoteCommit(context.repository, branch: target, at: root)
    let count = try await GitReviewService.checked(["rev-list", "--count",
      baseCommit + ".." + context.plan.commit], at: root).trimmingCharacters(in: .newlines)
    guard let ahead = Int(count), ahead >= 0 else { throw AgentFailure(message: "无法读取源分支的新提交。") }
    let plan = try await GitPushService.prepare(at: root, remote: context.plan.remote,
      destination: context.head, forceWithLease: false, allowDetached: true)
    let current = try await GitBatchService.capture(scope: .unstaged, at: root)
    guard plan == context.plan, current.signature == changes.signature else {
      throw GitHubPRRefreshRequired(message: "分支、远端或变更已改变，请重新检查 PR。")
    }
    try Task.checkCancellation()
    return Self(context: context, hasLocalChanges: hasChanges,
      hasConflicts: conflicts, commitsAhead: ahead, targetBranch: target)
  }
}
