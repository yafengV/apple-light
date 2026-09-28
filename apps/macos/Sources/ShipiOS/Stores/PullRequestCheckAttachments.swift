import AppKit
import Foundation

extension WorkspaceStore {
  var pullRequestCheckDraft: PullRequestCheckDraft? { library.pullRequestCheckDrafts[draftKey] }

  /// A detached PR reveals an owning task window without replacing main-window selection.
  func focusPullRequestCheckTaskWindow(_ taskID: String) -> Bool {
    guard library.tasks.contains(where: { $0.id == taskID && !$0.archived }),
      let resource = taskWindowResources.allObjects.first(where: { $0.tasks[taskID] != nil && $0.window != nil }),
      let window = resource.window else { return false }
    resource.navigate?(taskID)
    resource.tasks[taskID]?.revealChat()
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  func pullRequestCheckFixReason(_ request: GitHubPRChecksRequest, state: String?, branch: String?) -> String? {
    guard !restoringLibrary, !shuttingDown,
      let task = library.tasks.first(where: { $0.id == request.taskID }), !task.archived,
      task.isSideChat != true, !activityArchivingTaskIDs.contains(task.id),
      task.project == request.root.path, !task.project.isEmpty,
      !handoffBlocksProject(task.project) else { return "Fix 需要可用的任务工作区。" }
    guard let saved = library.taskPullRequests[task.id]?.first(where: {
      $0.validatedURL != nil && $0.validatedURL == request.pullRequest.validatedURL
        && $0.number == request.pullRequest.number
    }) else { return "无法确认此任务的 PR 信息。" }
    guard (state ?? saved.state)?.uppercased() == "OPEN" else { return "Fix 仅适用于开放的 PR。" }
    guard !request.pullRequest.headRefName.isEmpty, !request.pullRequest.baseRefName.isEmpty else {
      return "Fix 需要 PR 的来源和目标分支。"
    }
    guard let branch else { return "无法确认当前检出分支，请重试。" }
    guard branch == request.pullRequest.headRefName else { return "切回此 PR 的任务分支后才能使用 Fix。" }
    return nil
  }

  static func pullRequestCheckBranch(at root: URL) async throws -> String? {
    let result = try await LocalWorkspaceService.git(["symbolic-ref", "--short", "-q", "HEAD"], at: root)
    guard result.status == 0 else { return nil }
    let branch = result.text.trimmingCharacters(in: .newlines)
    return branch.isEmpty ? nil : branch
  }

  /// Fix only prepares a draft. The user remains responsible for submitting it.
  @discardableResult func attachPullRequestChecks(_ selected: [GitHubPRCheck],
    request: GitHubPRChecksRequest, snapshot: GitHubPRChecksSnapshot,
    valid: () -> Bool = { true },
    readBranch: (URL) async throws -> String? = { try await WorkspaceStore.pullRequestCheckBranch(at: $0) }
  ) async throws -> Bool {
    let failing = selected.filter { $0.status == .failing }
    guard !failing.isEmpty, snapshot.headRevision == request.headRevision,
      failing.allSatisfy({ snapshot.checks.contains($0) }), valid(), !Task.isCancelled else { return false }
    let original = library.pullRequestCheckDrafts[request.taskID]
    let originalPrompt = library.drafts[request.taskID]
    let branch = try await readBranch(request.root)
    guard valid(), !Task.isCancelled, library.pullRequestCheckDrafts[request.taskID] == original,
      library.drafts[request.taskID] == originalPrompt else { return false }
    if let reason = pullRequestCheckFixReason(request, state: snapshot.pullRequestState, branch: branch) {
      throw AgentFailure(message: reason)
    }
    var draft = original?.matches(request) == true ? original! : PullRequestCheckDraft(
      root: request.root.path, pullRequest: request.pullRequest, headRevision: request.headRevision, checks: [])
    var keys = draft.keys
    for var check in failing where keys.insert(check.attachmentKey).inserted {
      check = GitHubPRCheck(id: check.id, name: check.name, status: check.status,
        link: check.validatedLink?.absoluteString, description: check.description, workflow: check.workflow)
      draft.checks.append(check)
    }
    draft.id = UUID()
    guard draft.isValid else { throw AgentFailure(message: "PR 检查附件无效，请刷新后重试。") }
    var candidate = library
    candidate.pullRequestCheckDrafts[request.taskID] = draft
    candidate.drafts[request.taskID] = draft.fixPrompt
    try commitLibrary(candidate)
    if selectedTask?.id == request.taskID { action = .chat }
    return true
  }

  @discardableResult func removePullRequestChecks(_ keys: Set<String>, taskID: String,
    request: GitHubPRChecksRequest? = nil) -> Bool {
    guard var draft = library.pullRequestCheckDrafts[taskID],
      request == nil || draft.matches(request!) else { return false }
    let before = draft.checks.count
    draft.checks.removeAll { keys.contains($0.attachmentKey) }
    guard draft.checks.count != before else { return false }
    draft.id = UUID()
    var candidate = library
    candidate.pullRequestCheckDrafts[taskID] = draft.checks.isEmpty ? nil : draft
    do { try commitLibrary(candidate); return true }
    catch { self.error = error.localizedDescription; return false }
  }

  func promptWithPullRequestChecks(_ prompt: String, checks: PullRequestCheckDraft?, taskID: String?) throws -> String {
    guard let checks else { return prompt }
    guard let taskID, let task = library.tasks.first(where: { $0.id == taskID }),
      task.project == checks.root, !task.archived, task.isSideChat != true,
      !handoffBlocksProject(task.project), library.taskPullRequests[taskID]?.contains(where: {
        $0.validatedURL != nil && $0.validatedURL == checks.pullRequest.validatedURL
      }) == true else { throw AgentFailure(message: "PR 检查附件与任务工作区不匹配，请移除后重新添加。") }
    return try checks.appendingContext(to: prompt)
  }
}
