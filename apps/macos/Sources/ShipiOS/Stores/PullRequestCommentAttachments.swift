import Foundation

extension WorkspaceStore {
  @discardableResult func attachPullRequestComments(_ selected: [GitHubPRReviewThread],
    request: GitHubPRChecksRequest, snapshot: GitHubPRDiscussionSnapshot,
    valid: () -> Bool = { true },
    readBranch: (URL) async throws -> String? = { try await WorkspaceStore.pullRequestCheckBranch(at: $0) }
  ) async throws -> Bool {
    let attachments = selected.map { PullRequestCommentAttachment(thread: $0) }.filter(\.isValid)
    guard !attachments.isEmpty, request.pullRequest.url == snapshot.requestURL,
      request.headRevision == snapshot.head, selected.allSatisfy({ snapshot.threads.contains($0) }),
      valid(), !Task.isCancelled else { return false }
    let original = library.pullRequestCheckDrafts[request.taskID], prompt = library.drafts[request.taskID]
    let branch = try await readBranch(request.root)
    guard valid(), !Task.isCancelled, original == library.pullRequestCheckDrafts[request.taskID],
      prompt == library.drafts[request.taskID] else { return false }
    if let reason = pullRequestCheckFixReason(request, state: snapshot.state, branch: branch) { throw AgentFailure(message: reason) }
    var draft = original?.matches(request) == true ? original! : PullRequestCheckDraft(
      root: request.root.path, pullRequest: request.pullRequest, headRevision: request.headRevision, checks: [])
    var ids = Set(draft.comments.map(\.id))
    for attachment in attachments where ids.insert(attachment.id).inserted { draft.comments.append(attachment) }
    draft.id = UUID()
    var candidate = library
    let current = prompt ?? ""
    if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || current == original?.generatedPrompt || current == original?.fixPrompt {
      candidate.drafts[request.taskID] = draft.commentFixPrompt
      draft.generatedPrompt = draft.commentFixPrompt
    }
    guard draft.isValid else { throw AgentFailure(message: "PR 评论附件无效，请刷新后重新添加。") }
    candidate.pullRequestCheckDrafts[request.taskID] = draft
    try commitLibrary(candidate)
    if selectedTask?.id == request.taskID { action = .chat }
    return true
  }

  @discardableResult func removePullRequestComments(_ ids: Set<String>, taskID: String,
    request: GitHubPRChecksRequest? = nil) -> Bool {
    guard var draft = library.pullRequestCheckDrafts[taskID], request == nil || draft.matches(request!) else { return false }
    let original = draft
    draft.comments.removeAll { ids.contains($0.id) }
    guard draft.comments != original.comments else { return false }
    var candidate = library
    if draft.comments.isEmpty, reviewComments(taskID: taskID).isEmpty,
      candidate.drafts[taskID] == original.commentFixPrompt { candidate.drafts[taskID] = "" }
    draft.id = UUID()
    candidate.pullRequestCheckDrafts[taskID] = draft.comments.isEmpty && draft.checks.isEmpty ? nil : draft
    do { try commitLibrary(candidate); return true } catch { self.error = error.localizedDescription; return false }
  }

  @discardableResult func setPullRequestCommentGuidance(_ text: String, id: String, taskID: String) -> Bool {
    guard var draft = library.pullRequestCheckDrafts[taskID], let index = draft.comments.firstIndex(where: { $0.id == id }) else { return false }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard draft.comments[index].guidance != text else { return false }
    draft.comments[index].guidance = text; draft.id = UUID()
    var candidate = library; candidate.pullRequestCheckDrafts[taskID] = draft
    do { try commitLibrary(candidate); return true } catch { self.error = error.localizedDescription; return false }
  }
}
