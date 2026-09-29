import Foundation

extension GitHubPRService {
  func applyDiscussion(_ action: GitHubPRDiscussionAction, expected: GitHubPRDiscussionSnapshot,
    request: GitHubPullRequest, at root: URL, authorize: GitMutationAuthorization = {}) async throws -> GitHubPRDiscussionResult {
    let body: String?
    switch action {
    case .post(let value, _), .edit(_, _, let value):
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentFailure(message: "请填写评论。") }
      body = value
    case .review(let value, let decision, _):
      guard decision.accepts(value) else { throw AgentFailure(message: "请填写审查说明。") }
      body = value
    default: body = nil
    }
    guard (body?.utf8.count ?? 0) <= 65_536 else { throw AgentFailure(message: "评论不能超过 64 KiB。") }
    try await authorize()
    let fresh = try await discussion(for: request, at: root)
    guard expected.nodeID == fresh.nodeID, expected.requestURL.lowercased() == fresh.requestURL.lowercased(),
      expected.viewer.lowercased() == fresh.viewer.lowercased() else {
      throw GitHubPRDiscussionFailure(message: "PR 或 GitHub 账户已改变，请刷新后继续。", snapshot: fresh)
    }
    switch action {
    case .edit(let id, let kind, _), .delete(let id, let kind):
      guard expected.comment(id)?.kind == kind else { throw AgentFailure(message: "评论不属于当前 PR。") }
    case .resolve(let id, _), .post(_, .some(let id)):
      guard expected.threads.contains(where: { $0.id == id }) else { throw AgentFailure(message: "线程不属于当前 PR。") }
    default: break
    }
    let mutation = try Self.discussionMutation(action, fresh: fresh)
    // Existing-target mutations are idempotent on explicit retries after a lost response.
    if Self.discussionConfirmed(action, baseline: fresh, current: fresh) {
      return .init(snapshot: fresh)
    }
    try Task.checkCancellation(); try await authorize()
    let attempt = GitHubPRDiscussionAttempt(action: action, baseline: fresh)
    var receipt: JSONValue?
    var writeError: Error?
    do { receipt = try await discussionGraphQL(mutation.query, variables: ["input": .object(mutation.input)], at: root) }
    catch is CancellationError { throw CancellationError() }
    catch { writeError = error }
    try Task.checkCancellation()
    // Always reread, including when the server accepted a request but the CLI lost its response.
    do {
      let result = try await discussion(for: request, at: root)
      guard result.nodeID == fresh.nodeID, result.viewer.lowercased() == fresh.viewer.lowercased() else {
        throw AgentFailure(message: "GitHub 账户或 PR 在操作后发生变化。")
      }
      if Self.discussionConfirmed(action, baseline: fresh, current: result) { return .init(snapshot: result) }
      if let receipt, Self.discussionReceiptConfirms(action, receipt: receipt) {
        return .init(snapshot: Self.discussionApplyingReceipt(action, receipt: receipt, to: result),
          notice: "GitHub 已接受操作，活动列表稍后会重新读取。")
      }
      throw GitHubPRDiscussionFailure(message: writeError?.localizedDescription ?? "操作结果尚未确认，请重新读取。",
        snapshot: result, uncertain: action.creates && !(writeError is GitHubPRDiscussionRejected) ? attempt : nil)
    } catch is CancellationError { throw CancellationError() }
    catch let failure as GitHubPRDiscussionFailure { throw failure }
    catch {
      // A valid mutation receipt is sufficient to acknowledge a write; a refresh outage must not invite duplicate posts.
      if let receipt, Self.discussionReceiptConfirms(action, receipt: receipt) {
        return .init(snapshot: Self.discussionApplyingReceipt(action, receipt: receipt, to: fresh),
          notice: "GitHub 已接受操作，但活动刷新失败：" + error.localizedDescription)
      }
      throw GitHubPRDiscussionFailure(message: "操作结果尚未确认：" + (writeError ?? error).localizedDescription,
        snapshot: fresh, uncertain: action.creates && !(writeError is GitHubPRDiscussionRejected) ? attempt : nil)
    }
  }

  func confirmDiscussion(_ attempt: GitHubPRDiscussionAttempt, request: GitHubPullRequest, at root: URL) async throws -> GitHubPRDiscussionResult {
    let result = try await discussion(for: request, at: root)
    guard attempt.baseline.nodeID == result.nodeID,
      attempt.baseline.viewer.lowercased() == result.viewer.lowercased() else {
      throw GitHubPRDiscussionFailure(message: "账户或 PR 已改变，无法确认原操作。", snapshot: result, uncertain: attempt)
    }
    guard Self.discussionConfirmed(attempt.action, baseline: attempt.baseline, current: result) else {
      throw GitHubPRDiscussionFailure(message: "尚未找到唯一匹配的操作结果；没有重复发送。", snapshot: result, uncertain: attempt)
    }
    return .init(snapshot: result)
  }

  private static func discussionMutation(_ action: GitHubPRDiscussionAction,
    fresh: GitHubPRDiscussionSnapshot) throws -> (query: String, input: [String: JSONValue]) {
    var name: String, type: String, result: String, input: [String: JSONValue]
    switch action {
    case .post(let body, let thread):
      let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if let thread {
        guard let target = fresh.threads.first(where: { $0.id == thread }), target.canReply else {
          throw GitHubPRDiscussionFailure(message: "该线程不存在或不允许回复。", snapshot: fresh)
        }
        name = "addPullRequestReviewThreadReply"; type = "AddPullRequestReviewThreadReplyInput"
        input = ["pullRequestReviewThreadId": .string(thread), "body": .string(text)]
        result = "comment { \(discussionCommentFields) }"
      } else {
        name = "addComment"; type = "AddCommentInput"
        input = ["subjectId": .string(fresh.nodeID), "body": .string(text)]
        result = "commentEdge { node { \(discussionCommentFields) } }"
      }
    case .edit(let id, let kind, let body):
      guard let target = fresh.comment(id), target.kind == kind, target.canUpdate else {
        throw GitHubPRDiscussionFailure(message: "该评论不存在或不允许编辑。", snapshot: fresh)
      }
      if target.body == body { return ("", [:]) }
      switch kind {
      case .issue:
        name = "updateIssueComment"; type = "UpdateIssueCommentInput"; input = ["id": .string(id)]
        result = "issueComment { \(discussionCommentFields) }"
      case .review:
        name = "updatePullRequestReview"; type = "UpdatePullRequestReviewInput"; input = ["pullRequestReviewId": .string(id)]
        result = "pullRequestReview { \(discussionCommentFields) state commit { oid } }"
      case .code:
        name = "updatePullRequestReviewComment"; type = "UpdatePullRequestReviewCommentInput"; input = ["pullRequestReviewCommentId": .string(id)]
        result = "pullRequestReviewComment { \(discussionCommentFields) }"
      }
      input["body"] = .string(body) // Inline editing preserves the user's raw Markdown.
    case .delete(let id, let kind):
      guard kind != .review else { throw AgentFailure(message: "已提交的审查不能从评论删除入口删除。") }
      if fresh.comment(id) == nil { return ("", [:]) }
      guard let target = fresh.comment(id), target.kind == kind, target.canDelete else {
        throw GitHubPRDiscussionFailure(message: "该评论不允许删除。", snapshot: fresh)
      }
      name = kind == .issue ? "deleteIssueComment" : "deletePullRequestReviewComment"
      type = kind == .issue ? "DeleteIssueCommentInput" : "DeletePullRequestReviewCommentInput"
      input = ["id": .string(id)]; result = "clientMutationId"
    case .resolve(let thread, let resolved):
      guard let target = fresh.threads.first(where: { $0.id == thread }) else {
        throw GitHubPRDiscussionFailure(message: "该评论线程已移除。", snapshot: fresh)
      }
      if target.isResolved == resolved { return ("", [:]) }
      guard resolved ? target.canResolve : target.canUnresolve else {
        throw GitHubPRDiscussionFailure(message: "没有更改该线程解决状态的权限。", snapshot: fresh)
      }
      name = resolved ? "resolveReviewThread" : "unresolveReviewThread"
      type = resolved ? "ResolveReviewThreadInput" : "UnresolveReviewThreadInput"
      input = ["threadId": .string(thread)]; result = "thread { id isResolved }"
    case .review(let body, let decision, let head):
      guard fresh.canReview, fresh.head == head else {
        throw GitHubPRDiscussionFailure(message: "PR 已更新、关闭或当前账户为作者，请刷新后再提交审查。", snapshot: fresh)
      }
      name = "addPullRequestReview"; type = "AddPullRequestReviewInput"
      input = ["pullRequestId": .string(fresh.nodeID), "event": .string(decision.rawValue), "commitOID": .string(head)]
      let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { input["body"] = .string(text) }
      result = "pullRequestReview { \(discussionCommentFields) state commit { oid } }"
    }
    input["clientMutationId"] = .string(UUID().uuidString) // Correlation only; GitHub does not promise idempotency.
    return ("mutation ShipiOSPRDiscussionMutation($input:\(type)!) { action:\(name)(input:$input) { \(result) } }", input)
  }

  static func discussionConfirmed(_ action: GitHubPRDiscussionAction, baseline: GitHubPRDiscussionSnapshot,
    current: GitHubPRDiscussionSnapshot) -> Bool {
    switch action {
    case .edit(let id, let kind, let body): return current.comment(id).map { $0.kind == kind && $0.body == body } == true
    case .delete(let id, _): return current.comment(id) == nil
    case .resolve(let id, let resolved): return current.threads.first { $0.id == id }?.isResolved == resolved
    case .post(let body, let thread):
      let candidates = thread.map { id in current.threads.first { $0.id == id }?.comments ?? [] }
        ?? current.comments.filter { $0.kind == .issue }
      return candidates.filter { !baseline.commentIDs.contains($0.id) && $0.author.lowercased() == baseline.viewer.lowercased()
        && $0.body == body.trimmingCharacters(in: .whitespacesAndNewlines) }.count == 1
    case .review(let body, let decision, let head):
      return current.comments.filter { $0.kind == .review && !baseline.commentIDs.contains($0.id)
        && $0.author.lowercased() == baseline.viewer.lowercased() && $0.reviewState == decision.resultState
        && $0.commit == head && $0.body == body.trimmingCharacters(in: .whitespacesAndNewlines) }.count == 1
    }
  }

  private static func discussionReceiptConfirms(_ action: GitHubPRDiscussionAction, receipt: JSONValue) -> Bool {
    let result = receipt["action"]
    switch action {
    case .post(let body, let thread):
      let node = thread == nil ? result["commentEdge"]["node"] : result["comment"]
      return node["id"].text != nil && node["body"].text == body.trimmingCharacters(in: .whitespacesAndNewlines)
    case .edit(let id, let kind, let body):
      let node = result[kind == .issue ? "issueComment" : kind == .review ? "pullRequestReview" : "pullRequestReviewComment"]
      return node["id"].text == id && node["body"].text == body
    case .resolve(let id, let resolved): return result["thread"]["id"].text == id && result["thread"]["isResolved"].boolean == resolved
    case .delete: return result["clientMutationId"].text != nil
    case .review(let body, let decision, let head):
      let node = result["pullRequestReview"]
      return node["id"].text != nil && node["state"].text == decision.resultState && node["commit"]["oid"].text == head
        && node["body"].text == body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private static func discussionApplyingReceipt(_ action: GitHubPRDiscussionAction, receipt: JSONValue,
    to snapshot: GitHubPRDiscussionSnapshot) -> GitHubPRDiscussionSnapshot {
    var current = snapshot
    let result = receipt["action"]
    switch action {
    case .post(_, let thread):
      let node = thread == nil ? result["commentEdge"]["node"] : result["comment"]
      if let comment = try? discussionComment(node, kind: thread == nil ? .issue : .code) {
        if let thread, let index = current.threads.firstIndex(where: { $0.id == thread }) {
          if !current.threads[index].comments.contains(where: { $0.id == comment.id }) { current.threads[index].comments.append(comment) }
        } else if !current.comments.contains(where: { $0.id == comment.id }) { current.comments.append(comment) }
      }
    case .review:
      if let comment = try? discussionComment(result["pullRequestReview"], kind: .review), !current.comments.contains(where: { $0.id == comment.id }) {
        current.comments.append(comment)
      }
    case .edit(let id, let kind, _):
      let key = kind == .issue ? "issueComment" : kind == .review ? "pullRequestReview" : "pullRequestReviewComment"
      if let comment = try? discussionComment(result[key], kind: kind) {
        if let index = current.comments.firstIndex(where: { $0.id == id }) { current.comments[index] = comment }
        for index in current.threads.indices {
          if let child = current.threads[index].comments.firstIndex(where: { $0.id == id }) { current.threads[index].comments[child] = comment }
        }
      }
    case .delete(let id, _):
      current.comments.removeAll { $0.id == id }
      for index in current.threads.indices { current.threads[index].comments.removeAll { $0.id == id } }
      current.threads.removeAll { $0.comments.isEmpty }
    case .resolve(let id, let resolved):
      if let index = current.threads.firstIndex(where: { $0.id == id }) {
        let old = current.threads[index]
        current.threads[index] = .init(id: old.id, path: old.path, line: old.line, originalLine: old.originalLine,
          diffHunk: old.diffHunk, isResolved: resolved, isOutdated: old.isOutdated,
          canReply: old.canReply, canResolve: old.canResolve, canUnresolve: old.canUnresolve, comments: old.comments,
          diffSide: old.diffSide, startLine: old.startLine, startDiffSide: old.startDiffSide,
          originalStartLine: old.originalStartLine)
      }
    }
    return current
  }
}
