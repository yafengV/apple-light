import Foundation

extension GitHubPRService {
  func updateStatus(_ desired: GitHubPRStatus, expected: GitHubPRMergeSnapshot,
    request: GitHubPullRequest, at root: URL, authorize: GitMutationAuthorization = {}) async throws -> GitHubPRMergeSnapshot {
    try await authorize()
    var current = try await mergeSnapshot(for: request, at: root)
    try Self.verifyStatusOwner(current, expected: expected, request: request)
    if desired.confirmed(by: current) { return current }
    guard desired.canSelect(from: .init(current.details)) else {
      throw GitHubPRStatusFailure(message: "此状态不能直接切换，请刷新后重新选择。", snapshot: current)
    }
    let steps: [GitHubPRStatusStep]
    switch desired {
    case .draft: steps = [.draft]
    case .closed: steps = [.close]
    case .open:
      steps = current.details.state.uppercased() == "CLOSED"
        ? current.details.isDraft ? [.reopen, .ready] : [.reopen] : [.ready]
    case .merged: throw AgentFailure(message: "请使用合并操作。")
    }
    var changed = false
    for (index, step) in steps.enumerated() {
      if index > 0 {
        do {
          try await authorize()
          current = try await mergeSnapshot(for: request, at: root)
          try Self.verifyStatusOwner(current, expected: expected, request: request)
        } catch {
          try Task.checkCancellation()
          throw GitHubPRStatusFailure(message: "PR 已部分更新，后续操作未执行，请刷新后继续。",
            snapshot: current, requiresRefresh: true)
        }
      }
      if desired.confirmed(by: current) { return current }
      guard step.allowed(current), let node = current.nodeID else {
        throw GitHubPRStatusFailure(message: "PR 状态在操作期间改变，请刷新后重新选择。", snapshot: current)
      }
      let query = """
        mutation ShipiOSPRStatusMutation($input:\(step.inputType)!){
          action:\(step.rawValue)(input:$input){pullRequest{id number url state isDraft}}
        }
        """
      do { try Task.checkCancellation(); try await authorize() }
      catch {
        try Task.checkCancellation()
        if changed { throw GitHubPRStatusFailure(message: "PR 已部分更新，后续操作已取消。", snapshot: current) }
        throw error
      }
      var writeError: Error?
      do { _ = try await discussionGraphQL(query, variables: ["input": .object(["pullRequestId": .string(node)])], at: root) }
      catch { try Task.checkCancellation(); writeError = error }
      try Task.checkCancellation()
      let updated: GitHubPRMergeSnapshot
      do { updated = try await mergeSnapshot(for: request, at: root) }
      catch {
        try Task.checkCancellation()
        throw GitHubPRStatusFailure(message: "操作结果尚未确认，请刷新 PR 后再继续。\n" + (writeError ?? error).localizedDescription,
          requiresRefresh: true)
      }
      do { try Self.verifyStatusOwner(updated, expected: expected, request: request) }
      catch {
        throw GitHubPRStatusFailure(message: error.localizedDescription, snapshot: updated, requiresRefresh: true)
      }
      current = updated
      guard step.confirmed(updated) else {
        throw GitHubPRStatusFailure(message: (changed ? "PR 已部分更新，后续状态未能完成。\n" : "")
          + (writeError?.localizedDescription ?? "GitHub 尚未确认所选状态，请刷新后重试。"), snapshot: updated)
      }
      changed = true
    }
    guard desired.confirmed(by: current) else {
      throw GitHubPRStatusFailure(message: "PR 已更新，但所选最终状态尚未确认，请刷新。", snapshot: current, requiresRefresh: true)
    }
    return current
  }

  private static func verifyStatusOwner(_ fresh: GitHubPRMergeSnapshot, expected: GitHubPRMergeSnapshot,
    request: GitHubPullRequest) throws {
    guard let node = expected.nodeID, !node.isEmpty, let viewer = expected.viewer, !viewer.isEmpty,
      fresh.nodeID == node, fresh.viewer?.lowercased() == viewer.lowercased(),
      expected.repository == fresh.repository, expected.details.url.lowercased() == request.url.lowercased(),
      fresh.details.url.lowercased() == request.url.lowercased(), expected.isAuthor, fresh.isAuthor,
      fresh.details.state.uppercased() != "MERGED" else {
      throw GitHubPRStatusFailure(message: "PR、GitHub 账户或作者权限已改变，或此 PR 已合并。请刷新。", snapshot: fresh)
    }
  }
}
