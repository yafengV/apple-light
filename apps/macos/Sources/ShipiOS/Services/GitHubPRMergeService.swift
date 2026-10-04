import Foundation

extension GitHubPRService {
  func mergeSnapshot(for request: GitHubPullRequest, at root: URL) async throws -> GitHubPRMergeSnapshot {
    guard let url = request.validatedURL else { throw AgentFailure(message: "保存的 PR 地址无效。") }
    let parts = url.pathComponents
    let repository = try GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])")
    let details = try await details(for: request, at: root)
    let query = """
      query ShipiOSPRMerge($owner:String!,$name:String!,$number:Int!){
        viewer{login}
        repository(owner:$owner,name:$name){
          nameWithOwner mergeCommitAllowed squashMergeAllowed
          pullRequest(number:$number){
            id number url state isDraft headRefOid headRefName baseRefName
            author{login} autoMergeRequest{enabledAt}
          }
        }
      }
      """
    let output = try await run(["api", "graphql", "--hostname", "github.com", "-f", "query=" + query,
      "-f", "owner=" + repository.owner, "-f", "name=" + repository.name,
      "-F", "number=\(request.number)"], at: root)
    let response = try JSONDecoder().decode(PRMergeMetadata.self, from: Data(output.utf8))
    guard response.errors?.isEmpty != false, let data = response.data, let repo = data.repository,
      let pr = repo.pullRequest,
      repo.nameWithOwner.lowercased() == repository.fullName.lowercased(),
      pr.number == request.number, repository.pullRequestURL(pr.url) == url,
      pr.state.uppercased() == details.state.uppercased(), pr.isDraft == details.isDraft,
      pr.headRefOid == details.headRefOid, pr.headRefName == details.headRefName,
      pr.baseRefName == details.baseRefName, !data.viewer.login.isEmpty else {
      throw GitHubPRRefreshRequired(message: "PR 或合并配置在读取时发生变化，请刷新后重试。")
    }
    var methods: [GitHubPRMergeMethod] = []
    if repo.mergeCommitAllowed { methods.append(.merge) }
    if repo.squashMergeAllowed { methods.append(.squash) }
    return GitHubPRMergeSnapshot(details: details, repository: repository,
      isAuthor: pr.author?.login.caseInsensitiveCompare(data.viewer.login) == .orderedSame,
      allowedMethods: methods, isAutoMergeEnabled: pr.autoMergeRequest != nil,
      viewer: data.viewer.login, nodeID: pr.id)
  }

  /// Refresh before mutation, then make GitHub enforce the exact displayed head revision.
  /// No local checkout, branch deletion, administrator bypass or automatic retry is used.
  func apply(_ action: GitHubPRMergeAction, to expected: GitHubPRMergeSnapshot,
    request: GitHubPullRequest, at root: URL,
    authorize: GitMutationAuthorization = {}) async throws -> GitHubPRMergeResult {
    try await authorize()
    let fresh = try await mergeSnapshot(for: request, at: root)
    if action.isConfirmed(by: fresh) {
      return GitHubPRMergeResult(snapshot: fresh, notice: nil)
    }
    guard expected.details.url == fresh.details.url, expected.repository == fresh.repository,
      let head = expected.headRevision, head == fresh.headRevision,
      expected.details.headRefName == fresh.details.headRefName,
      expected.details.baseRefName == fresh.details.baseRefName else {
      throw GitHubPRMergeFailure(message: "PR 的头提交或目标分支已改变，请刷新并重新确认。", snapshot: fresh)
    }
    let reason: String?
    switch action {
    case .merge: reason = fresh.mergeDisabledReason
    case .autoMerge: reason = fresh.autoMergeDisabledReason
    }
    if let reason { throw GitHubPRMergeFailure(message: reason, snapshot: fresh) }
    var args = ["pr", "merge", String(request.number), "--repo", fresh.repository.fullName]
    switch action {
    case .merge(let method), .autoMerge(true, let method):
      guard fresh.allowedMethods.contains(method) else {
        throw GitHubPRMergeFailure(message: "仓库已不允许所选合并方式，请重新选择。", snapshot: fresh)
      }
      args += [method.cliFlag, "--match-head-commit", head]
      if case .autoMerge = action { args.append("--auto") }
    case .autoMerge(false, _): args.append("--disable-auto")
    }
    try await authorize()
    try Task.checkCancellation()
    var failure: Error?
    do { _ = try await run(args, at: root) }
    catch {
      try Task.checkCancellation()
      failure = error
    }
    try Task.checkCancellation()
    let updated: GitHubPRMergeSnapshot
    do { updated = try await mergeSnapshot(for: request, at: root) }
    catch {
      try Task.checkCancellation()
      throw GitHubPRMergeFailure(message: "操作结果尚未确认，请刷新 PR 状态后再继续。\n\(failure?.localizedDescription ?? error.localizedDescription)",
        snapshot: nil)
    }
    if let failure, !action.isConfirmed(by: updated) {
      throw GitHubPRMergeFailure(message: failure.localizedDescription, snapshot: updated)
    }
    return GitHubPRMergeResult(snapshot: updated,
      notice: action.isConfirmed(by: updated) ? nil : "合并请求已发送，GitHub 尚未确认完成。请刷新状态。")
  }
}

private struct PRMergeMetadata: Decodable {
  struct APIError: Decodable { let message: String }
  struct Actor: Decodable { let login: String }
  struct AutoMerge: Decodable { let enabledAt: String? }
  struct Request: Decodable {
    let id: String?
    let number: Int
    let url: String
    let state: String
    let isDraft: Bool
    let headRefOid: String
    let headRefName: String
    let baseRefName: String
    let author: Actor?
    let autoMergeRequest: AutoMerge?
  }
  struct Repository: Decodable {
    let nameWithOwner: String
    let mergeCommitAllowed: Bool
    let squashMergeAllowed: Bool
    let pullRequest: Request?
  }
  struct Payload: Decodable {
    let viewer: Actor
    let repository: Repository?
  }
  let data: Payload?
  let errors: [APIError]?
}
