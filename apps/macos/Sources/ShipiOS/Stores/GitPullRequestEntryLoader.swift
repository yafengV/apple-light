import Foundation
import Observation

struct GitPullRequestEntryRequest: Equatable {
  let root: URL?
  let revision: UUID
  let generation: UUID
  let epoch: UUID
  var base: String? = nil
  var taskID: String? = nil
  var suspended = false
}

@MainActor @Observable final class GitPullRequestEntryLoader {
  private(set) var request: GitPullRequestEntryRequest?
  private(set) var readiness: GitPullRequestReadiness?
  private(set) var error: String?
  private(set) var loading = false
  private(set) var opening = false
  @ObservationIgnored private var token = UUID()

  func load(_ request: GitPullRequestEntryRequest,
    read: (URL, String?) async throws -> GitPullRequestReadiness) async {
    let operation = UUID()
    token = operation; self.request = request
    readiness = nil; error = nil; loading = false
    guard let root = request.root, !request.suspended else { return }
    loading = true
    defer { if token == operation { loading = false } }
    do {
      let result = try await read(root, request.base)
      guard token == operation, !Task.isCancelled else { return }
      readiness = result
    } catch {
      guard token == operation, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  func cancel() {
    token = UUID(); readiness = nil; error = nil; loading = false
  }

  func openExisting(in workspace: DeveloperWorkspace, store: WorkspaceStore, taskID: String?,
    openURL: @MainActor (URL) -> Bool) async {
    guard !opening, !loading, let value = readiness, let existing = value.context.existing,
      let url = value.context.repository.pullRequestURL(existing.url),
      request?.root == value.context.plan.root, request?.taskID == taskID, request?.suspended == false,
      workspace.gitRoot == value.context.plan.root else { return }
    opening = true; error = nil
    defer { opening = false }
    let operation = token, draft = workspace.pullRequestDraft
    let project = workspace.root
    let authorize = workspace.gitRepositoryAuthorization(at: value.context.plan.root)
    do {
      try authorize()
      let plan = try await GitPushService.prepare(at: value.context.plan.root,
        remote: value.context.plan.remote, destination: value.context.head, forceWithLease: false)
      try authorize()
      guard token == operation, workspace.pullRequestDraft === draft, plan == value.context.plan else {
        throw GitHubPRRefreshRequired(message: "分支或远端已改变，请重新检查 PR。")
      }
      guard openURL(url) else { throw AgentFailure(message: "无法打开系统浏览器，请重试。") }
      workspace.gitActionStatus = "已在浏览器中打开 PR 页面"
      if let project { _ = store.recordPullRequest(existing, for: taskID, at: project,
        repository: value.context.repository) }
    } catch {
      if token == operation, workspace.pullRequestDraft === draft, !(error is CancellationError) {
        self.error = error.localizedDescription
      }
    }
  }
}
