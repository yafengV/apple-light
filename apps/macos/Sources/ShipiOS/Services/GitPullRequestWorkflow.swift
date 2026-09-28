import Foundation

/// Captures the local selection and remote identity before generating text or changing Git.
struct GitPullRequestWorkflow {
  let context: GitHubPRContext
  let base: String
  let baseCommit: String
  let includeLocalChanges: Bool
  let selection: GitCommitSelection?
  let intendedTree: String?
  let newBranch: String?
  let newBranchPlan: GitPushPlan?
  let branchSnapshot: GitBranchSnapshot?

  static func prepare(_ context: GitHubPRContext, base: String, includeLocalChanges: Bool,
    service: GitHubPRService, newBranch: String? = nil) async throws -> Self {
    let root = context.plan.root
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + base], at: root)
    guard valid.status == 0, base != (newBranch ?? context.head) else {
      throw AgentFailure(message: "请选择有效且不同于源分支的目标分支。")
    }
    let fresh = try await service.inspect(at: root, remote: context.plan.remote, allowUnpublished: true)
    guard fresh.plan == context.plan, fresh.repository == context.repository,
      fresh.publishedCommit == context.publishedCommit, fresh.existing == nil else {
      throw GitHubPRRefreshRequired(message: "分支、提交、远端或 PR 状态已改变，请重新检查。")
    }
    if let problem = fresh.creationProblem { throw AgentFailure(message: problem) }
    var branchPlan: GitPushPlan?
    var branchSnapshot: GitBranchSnapshot?
    if fresh.requiresNewBranch {
      guard let newBranch else { throw AgentFailure(message: "请填写新分支名称。") }
      try await GitCommitSelection.validateBranch(newBranch, at: root)
      branchPlan = try await GitPushService.prepare(at: root, remote: context.plan.remote,
        destination: newBranch, forceWithLease: false, allowDetached: true)
      branchSnapshot = try await GitBranchService.snapshot(at: root)
      guard branchSnapshot?.currentReference == nil,
        branchSnapshot?.currentCommit == context.plan.commit else {
        throw GitHubPRRefreshRequired(message: "源提交已改变，请重新检查。")
      }
    } else if newBranch != nil {
      throw GitHubPRRefreshRequired(message: "当前已在命名分支上，请重新检查 PR。")
    }
    if !includeLocalChanges && !fresh.requiresNewBranch && fresh.publishedCommit == nil {
      throw AgentFailure(message: "此分支尚未发布，请勾选“提交并推送本地变更”或先推送分支。")
    }
    let baseCommit = try await service.remoteCommit(context.repository, branch: base, at: root)
    var selection: GitCommitSelection?
    var tree: String?
    if includeLocalChanges {
      let changes = try await GitBatchService.capture(scope: .unstaged, at: root)
      if changes.files.contains(where: { $0.staged || $0.unstaged }) {
        selection = try await GitCommitSelection.capture(at: root, includeUnstaged: true, newBranch: newBranch)
        tree = try await GitCommitIndex.withSelection(at: root, includeUnstaged: true) { index in
          let value = try await LocalWorkspaceService.git(["write-tree"], at: root, indexFile: index)
          guard value.status == 0 else { throw AgentFailure(message: value.text) }
          return value.text.trimmingCharacters(in: .newlines)
        }
      }
    }
    let result = Self(context: fresh, base: base, baseCommit: baseCommit,
      includeLocalChanges: includeLocalChanges, selection: selection, intendedTree: tree,
      newBranch: newBranch, newBranchPlan: branchPlan, branchSnapshot: branchSnapshot)
    if newBranch != nil && selection == nil {
      let ahead = try await GitReviewService.checked(["rev-list", "--count",
        baseCommit + ".." + context.plan.commit], at: root)
      guard (Int(ahead.trimmingCharacters(in: .newlines)) ?? 0) > 0 else {
        throw AgentFailure(message: "源提交没有相对目标分支的新提交，请包含本地变更后再创建 PR。")
      }
    }
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
    if let newBranch, let newBranchPlan {
      try await GitCommitSelection.validateBranch(newBranch, at: context.plan.root)
      guard try await GitPushService.prepare(at: context.plan.root, remote: context.plan.remote,
        destination: newBranch, forceWithLease: false, allowDetached: true) == newBranchPlan else {
        throw GitHubPRRefreshRequired(message: "新分支目标或远端已改变，请重新检查。")
      }
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
    let head = includeLocalChanges || newBranch != nil ? context.plan.commit : context.publishedCommit
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
      diff: diff, commits: commits, localDiff: local, needsCommitMessage: needsCommitMessage, proposedHead: newBranch)
  }

  func execute(service: GitHubPRService, title: String, body: String, draft: Bool,
    commitMessage: String, forceWithLease: Bool, openInBrowser: Bool = false, authorize: GitMutationAuthorization,
    onPhase: @MainActor (String) -> Void,
    onCommitted: @MainActor () -> Void,
    onPushed: @MainActor (String) -> Void) async throws -> GitPullRequestDestination {
    try await validate(service: service)
    var expectedHead = context.plan.commit
    let targetBranch = newBranch ?? context.plan.branch
    let targetDestination = newBranchPlan?.destination ?? context.plan.destination
    let expectedRemote = newBranchPlan?.expectedRemoteCommit ?? context.plan.expectedRemoteCommit
    if let newBranch, selection == nil, let branchSnapshot {
      await onPhase("正在创建分支…")
      try await GitBranchService.apply(.create(name: newBranch, startingAt: nil),
        snapshot: branchSnapshot, authorize: authorize)
    }
    if let selection {
      let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty, message.utf8.count <= 16_384 else {
        throw AgentFailure(message: "请填写或生成有效的提交说明。")
      }
      await onPhase(newBranch == nil ? "正在提交本地变更…" : "正在创建分支并提交本地变更…")
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
    guard current.plan.branch == targetBranch, current.plan.commit == expectedHead,
      current.plan.destination == targetDestination, current.plan.pushURL == context.plan.pushURL,
      current.repository == context.repository else {
      throw GitHubPRRefreshRequired(message: "分支或远端已改变，未继续推送或创建 PR。")
    }
    if (includeLocalChanges || newBranch != nil) && current.requiresPush {
      await onPhase("正在推送分支…")
      let plan = try await GitPushService.prepare(at: context.plan.root, remote: context.plan.remote,
        destination: newBranch ?? context.head, forceWithLease: forceWithLease)
      guard plan.commit == expectedHead, plan.pushURL == context.plan.pushURL,
        plan.expectedRemoteCommit == expectedRemote else {
        throw GitHubPRRefreshRequired(message: "推送目标或跟踪引用已改变，请重新检查后推送。")
      }
      let warning = try await GitPushService.push(plan, authorize: authorize)
      await onPushed(warning ?? "已推送 \(plan.branch)")
      current = try await service.inspect(at: context.plan.root, remote: context.plan.remote)
    }
    guard current.plan.branch == targetBranch, current.plan.commit == expectedHead,
      current.plan.destination == targetDestination, current.plan.pushURL == context.plan.pushURL,
      current.repository == context.repository,
      includeLocalChanges || newBranch != nil || current.publishedCommit == context.publishedCommit,
      try await service.remoteCommit(context.repository, branch: base, at: context.plan.root) == baseCommit else {
      throw GitHubPRRefreshRequired(message: "分支或目标提交已改变，请重新检查后创建 PR。")
    }
    if openInBrowser {
      await onPhase("正在准备浏览器 PR 页面…")
      return try await service.browserDestination(current, base: base, title: title, body: body,
        publishedOnly: !includeLocalChanges && newBranch == nil, authorize: authorize)
    }
    await onPhase("正在创建 PR…")
    return .pullRequest(try await service.create(current, base: base, title: title, body: body, draft: draft,
      publishedOnly: !includeLocalChanges && newBranch == nil, authorize: authorize))
  }
}
