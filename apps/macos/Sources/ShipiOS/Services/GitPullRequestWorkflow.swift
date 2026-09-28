import Foundation

/// Captures the local selection and remote identity before generating text or changing Git.
struct GitPullRequestWorkflow {
  let context: GitHubPRContext
  let base: String
  let baseCommit: String
  let includeLocalChanges: Bool
  let selection: GitCommitSelection?
  let intendedTree: String?

  static func prepare(_ context: GitHubPRContext, base: String, includeLocalChanges: Bool,
    service: GitHubPRService) async throws -> Self {
    let root = context.plan.root
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + base], at: root)
    guard valid.status == 0, base != context.head else {
      throw AgentFailure(message: "请选择有效且不同于源分支的目标分支。")
    }
    let fresh = try await service.inspect(at: root, remote: context.plan.remote, allowUnpublished: true)
    guard fresh.plan == context.plan, fresh.repository == context.repository,
      fresh.publishedCommit == context.publishedCommit, fresh.existing == nil else {
      throw GitHubPRRefreshRequired(message: "分支、提交、远端或 PR 状态已改变，请重新检查。")
    }
    if let problem = fresh.creationProblem { throw AgentFailure(message: problem) }
    if !includeLocalChanges && fresh.publishedCommit == nil {
      throw AgentFailure(message: "此分支尚未发布，请勾选“提交并推送本地变更”或先推送分支。")
    }
    let baseCommit = try await service.remoteCommit(context.repository, branch: base, at: root)
    var selection: GitCommitSelection?
    var tree: String?
    if includeLocalChanges {
      let changes = try await GitBatchService.capture(scope: .unstaged, at: root)
      if changes.files.contains(where: { $0.staged || $0.unstaged }) {
        selection = try await GitCommitSelection.capture(at: root, includeUnstaged: true, newBranch: nil)
        tree = try await GitCommitIndex.withSelection(at: root, includeUnstaged: true) { index in
          let value = try await LocalWorkspaceService.git(["write-tree"], at: root, indexFile: index)
          guard value.status == 0 else { throw AgentFailure(message: value.text) }
          return value.text.trimmingCharacters(in: .newlines)
        }
      }
    }
    let result = Self(context: fresh, base: base, baseCommit: baseCommit,
      includeLocalChanges: includeLocalChanges, selection: selection, intendedTree: tree)
    try await result.validate(service: service)
    return result
  }

  func validate(service: GitHubPRService) async throws {
    let fresh = try await service.inspect(at: context.plan.root, remote: context.plan.remote,
      allowUnpublished: true)
    guard fresh.plan == context.plan, fresh.repository == context.repository,
      fresh.publishedCommit == context.publishedCommit, fresh.existing == nil,
      try await service.remoteCommit(context.repository, branch: base, at: context.plan.root) == baseCommit else {
      throw GitHubPRRefreshRequired(message: "分支、远端或 PR 状态已改变，请重新检查。")
    }
    if let selection {
      let changes = try await GitBatchService.capture(scope: .unstaged, at: context.plan.root)
      guard changes.signature == selection.changes.signature else {
        throw GitHubPRRefreshRequired(message: "本地变更或索引已改变，请重新检查。")
      }
    }
    try Task.checkCancellation()
  }

  func content(needsCommitMessage: Bool) async throws -> GitPullRequestContent {
    let head = includeLocalChanges ? context.plan.commit : context.publishedCommit
    guard let head else { throw AgentFailure(message: "此分支尚未发布。") }
    let root = context.plan.root
    let merge = try await GitReviewService.checked(["merge-base", baseCommit, head], at: root)
      .trimmingCharacters(in: .newlines)
    let target = intendedTree ?? head
    let args = ["diff", "--no-ext-diff", "--no-textconv", "--full-index", "--find-renames",
      "--src-prefix=a/", "--dst-prefix=b/"]
    let diff = try await GitReviewService.checked(args + [merge, target, "--"], at: root)
    let commits = try await GitReviewService.checked(["log", "--format=%s%n%b", baseCommit + ".." + head, "--"], at: root)
    var local: String?
    if let tree = intendedTree { local = try await GitReviewService.checked(args + [head, tree, "--"], at: root) }
    guard !commits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || local != nil else {
      throw AgentFailure(message: "源分支没有相对目标分支的新提交或待提交内容。")
    }
    guard diff.utf8.count + commits.utf8.count + (local?.utf8.count ?? 0) <= 524_288 else {
      throw AgentFailure(message: "PR 变更超过 512 KiB，请手动填写标题、描述和提交说明。")
    }
    return GitPullRequestContent(context: context, base: base, baseCommit: baseCommit,
      diff: diff, commits: commits, localDiff: local, needsCommitMessage: needsCommitMessage)
  }

  func execute(service: GitHubPRService, title: String, body: String, draft: Bool,
    commitMessage: String, forceWithLease: Bool, authorize: GitMutationAuthorization,
    onPhase: @MainActor (String) -> Void,
    onCommitted: @MainActor () -> Void,
    onPushed: @MainActor (String) -> Void) async throws -> GitHubPullRequest {
    try await validate(service: service)
    var expectedHead = context.plan.commit
    if let selection {
      let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty, message.utf8.count <= 16_384 else {
        throw AgentFailure(message: "请填写或生成有效的提交说明。")
      }
      await onPhase("正在提交本地变更…")
      try await selection.apply(authorize: authorize)
      try await authorize()
      _ = try await GitReviewService.checked(["commit", "-m", message], at: context.plan.root)
      await onCommitted()
      expectedHead = try await GitReviewService.checked(["rev-parse", "HEAD"], at: context.plan.root)
        .trimmingCharacters(in: .newlines)
      let tree = try await GitReviewService.checked(["rev-parse", "HEAD^{tree}"], at: context.plan.root)
        .trimmingCharacters(in: .newlines)
      let parent = try await GitReviewService.checked(["rev-parse", "HEAD^"], at: context.plan.root)
        .trimmingCharacters(in: .newlines)
      guard tree == intendedTree, parent == context.plan.commit else {
        throw GitHubPRRefreshRequired(message: "提交已成功，但实际提交内容或分支发生变化，请重新检查后继续推送。")
      }
    }
    var current = try await service.inspect(at: context.plan.root, remote: context.plan.remote, allowUnpublished: true)
    guard current.plan.branch == context.plan.branch, current.plan.commit == expectedHead,
      current.plan.destination == context.plan.destination, current.plan.pushURL == context.plan.pushURL,
      current.repository == context.repository else {
      throw GitHubPRRefreshRequired(message: "分支或远端已改变，未继续推送或创建 PR。")
    }
    if includeLocalChanges && current.requiresPush {
      await onPhase("正在推送分支…")
      let plan = try await GitPushService.prepare(at: context.plan.root, remote: context.plan.remote,
        destination: context.head, forceWithLease: forceWithLease)
      guard plan.commit == expectedHead, plan.pushURL == context.plan.pushURL,
        plan.expectedRemoteCommit == context.plan.expectedRemoteCommit else {
        throw GitHubPRRefreshRequired(message: "推送目标或跟踪引用已改变，请重新检查后推送。")
      }
      let warning = try await GitPushService.push(plan, authorize: authorize)
      await onPushed(warning ?? "已推送 \(plan.branch)")
      current = try await service.inspect(at: context.plan.root, remote: context.plan.remote)
    }
    guard current.plan.branch == context.plan.branch, current.plan.commit == expectedHead,
      current.plan.destination == context.plan.destination, current.plan.pushURL == context.plan.pushURL,
      current.repository == context.repository,
      includeLocalChanges || current.publishedCommit == context.publishedCommit,
      try await service.remoteCommit(context.repository, branch: base, at: context.plan.root) == baseCommit else {
      throw GitHubPRRefreshRequired(message: "分支或目标提交已改变，请重新检查后创建 PR。")
    }
    await onPhase("正在创建 PR…")
    return try await service.create(current, base: base, title: title, body: body, draft: draft,
      publishedOnly: !includeLocalChanges, authorize: authorize)
  }
}
