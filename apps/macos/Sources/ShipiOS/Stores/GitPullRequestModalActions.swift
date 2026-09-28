import Foundation
import AppKit

/// Keeps a disappearing modal or late workflow from resetting another repository's form.
@MainActor final class GitPullRequestModalScope {
  let workspace: DeveloperWorkspace
  let draft: GitHubPRDraft
  private let root: URL?
  private let generation: UUID
  private let epoch: UUID
  private var handingOffAction = false

  init(workspace: DeveloperWorkspace) {
    self.workspace = workspace; draft = workspace.pullRequestDraft
    root = workspace.gitRoot; generation = workspace.generationForGitMutation
    epoch = workspace.reviewRepositoryEpoch
  }
  var isCurrent: Bool {
    workspace.pullRequestDraft === draft && workspace.gitRoot == root
      && workspace.generationForGitMutation == generation && workspace.reviewRepositoryEpoch == epoch
  }
  var canStartAction: Bool { isCurrent && !handingOffAction }
  func handOffAction() { handingOffAction = true }
  func disappear() {
    guard isCurrent else { return }
    draft.modalDidDisappear(handingOffAction: handingOffAction)
  }
  func settle(_ action: GitPullRequestAction, reservation: UUID) {
    draft.finishModalAction(reservation, reset: isCurrent && action != .openBrowser)
  }
}

extension WorkspaceStore {
  /// The modal's lifecycle is outside the Git workflow, matching the reference's onSettled reset.
  /// This synchronous acceptance captures ownership before dismissal schedules the background task.
  @discardableResult func beginPullRequestAction(_ action: GitPullRequestAction,
    in workspace: DeveloperWorkspace, taskID: String? = nil,
    openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Task<Void, Never>? {
    let scope = GitPullRequestModalScope(workspace: workspace)
    let state = scope.draft
    guard !state.loading, !state.creating, let root = workspace.gitRoot,
      state.context?.plan.root == root else { return nil }
    let existingURL: URL?
    if action == .openExisting {
      guard let existing = state.existing,
        let url = state.context?.repository.pullRequestURL(existing.url) else { return nil }
      existingURL = url
    } else {
      guard state.canCreate, workspace.isPrimaryReviewRepository,
        !library.gitPreferences.readOnlyReview, !workspace.gitBusy, !workspace.gitActionRunning else { return nil }
      existingURL = nil
    }
    guard let reservation = state.reserveModalAction() else { return nil }
    state.clearError()
    return Task {
      defer { scope.settle(action, reservation: reservation) }
      guard scope.isCurrent else { return }
      if let existingURL {
        if openURL(existingURL) { workspace.gitActionStatus = "已在浏览器中打开 PR 页面" }
        else { state.reportError("无法打开系统浏览器，请重试。") }
      } else {
        await self.createPullRequest(in: workspace, draft: action == .createDraft,
          taskID: taskID, openInBrowser: action == .openBrowser, openURL: openURL)
      }
    }
  }
}
