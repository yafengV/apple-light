import Foundation
import Observation

struct GitWorkflowCommandRequest: Equatable {
  let repository: GitPullRequestEntryRequest
  let primary: Bool
}

struct GitWorkflowCommandSnapshot: Sendable {
  let canCommit: Bool
  let canPush: Bool
  let pullRequest: GitPullRequestReadiness?
  let pullRequestError: String?
  var branchName: String? = nil
  var defaultBranch: String? = nil

  var showsPullRequest: Bool {
    guard let value = pullRequest, value.context.existing == nil else { return false }
    if value.context.requiresNewBranch {
      return (value.hasLocalChanges && !value.hasConflicts) || value.commitsAhead > 0
    }
    return value.context.plan.branch != value.context.defaultBranch
  }

  static func capture(at root: URL, primary: Bool,
    inspect: (URL) async throws -> GitPullRequestReadiness) async throws -> Self {
    let before = try await GitBranchService.snapshot(at: root)
    guard before.canChange else { throw AgentFailure(message: "仓库范围已改变，请刷新后重试。") }
    let changes = try await GitBatchService.capture(scope: .unstaged, at: root)
    let conflicts = changes.files.contains(where: \.conflicted)
    let canCommit = conflicts ? false : try await GitCommitSummary.capture(at: root, includeUnstaged: true).hasChanges
    var canPush = false
    // Opening the options does not require GitHub or a network request. A local
    // tracking reference qualifies the push path; the modal rechecks its target.
    if before.currentReference != nil, before.currentCommit != nil,
      let choices = try? await GitPushService.choices(at: root),
      let plan = try? await GitPushService.prepare(at: root, remote: choices.preferredRemote,
        destination: choices.preferredDestination, forceWithLease: false) {
      if plan.expectedRemoteCommit.isEmpty { canPush = true }
      else {
        let count = try await GitReviewService.checked(["rev-list", "--count",
          plan.expectedRemoteCommit + ".." + plan.commit], at: root)
        canPush = (Int(count.trimmingCharacters(in: .newlines)) ?? 0) > 0
      }
    }
    var readiness: GitPullRequestReadiness?, hostingError: String?
    if primary {
      do { readiness = try await inspect(root) }
      catch is CancellationError { throw CancellationError() }
      catch { hostingError = error.localizedDescription }
    }
    let after = try await GitBranchService.snapshot(at: root)
    let current = try await GitBatchService.capture(scope: .unstaged, at: root)
    guard before.currentReference == after.currentReference,
      before.currentCommit == after.currentCommit, changes.signature == current.signature else {
      throw AgentFailure(message: "分支或变更已改变，请重新检查 Git 命令。")
    }
    try Task.checkCancellation()
    let defaultBranch: String?
    if let hosted = readiness?.context.defaultBranch { defaultBranch = hosted }
    else {
      let head = try await LocalWorkspaceService.git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], at: root)
      let reference = head.text.trimmingCharacters(in: .newlines)
      if head.status == 0, reference.hasPrefix("refs/remotes/origin/") {
        defaultBranch = String(reference.dropFirst("refs/remotes/origin/".count))
      } else {
        defaultBranch = ["main", "master"].first { name in before.branches.contains { $0.reference == "refs/heads/" + name } }
      }
    }
    return Self(canCommit: canCommit, canPush: canPush, pullRequest: readiness, pullRequestError: hostingError,
      branchName: before.currentReference.map { String($0.dropFirst("refs/heads/".count)) }, defaultBranch: defaultBranch)
  }
}

@MainActor @Observable final class GitWorkflowCommandState {
  private(set) var request: GitWorkflowCommandRequest?
  private(set) var snapshot: GitWorkflowCommandSnapshot?
  private(set) var loading = false
  private(set) var error: String?
  @ObservationIgnored private var token = UUID()

  func load(_ request: GitWorkflowCommandRequest,
    read: (URL, Bool) async throws -> GitWorkflowCommandSnapshot) async {
    let operation = UUID()
    token = operation; self.request = request; snapshot = nil; error = nil; loading = false
    guard let root = request.repository.root, !request.repository.suspended else { return }
    loading = true
    defer { if token == operation { loading = false } }
    do {
      let result = try await read(root, request.primary)
      guard token == operation, !Task.isCancelled else { return }
      snapshot = result
    } catch {
      guard token == operation, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }

  func cancel() { token = UUID(); snapshot = nil; loading = false; error = nil }
}
