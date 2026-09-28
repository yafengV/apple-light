import SwiftUI

/// The focused window owns both metadata and presentation. No fallback to main selection.
@MainActor struct GitWorkflowCommandContext {
  static let ids = ["git.commit", "git.createPullRequest", "git.createDraftPullRequest"]
  static func owns(_ id: String) -> Bool { ids.contains(id) }
  let store: WorkspaceStore
  let workspace: DeveloperWorkspace
  let taskID: String?
  let request: GitWorkflowCommandRequest
  let available: () -> Bool
  var currentTaskID: (() -> String?)? = nil

  func visible(_ id: String) -> Bool {
    guard Self.owns(id) else { return false }
    if id == "git.commit" { return true }
    return workspace.gitCommands.request == request && request.primary
      && workspace.gitCommands.snapshot?.showsPullRequest == true
  }
  func enabled(_ id: String) -> Bool {
    guard visible(id), available(), currentTaskID.map({ $0() == taskID }) ?? true,
      workspace.generationForGitMutation == request.repository.generation,
      workspace.reviewRepositoryEpoch == request.repository.epoch,
      workspace.reviewSnapshot == request.repository.revision, workspace.gitCommands.request == request,
      request.repository.taskID == taskID,
      !request.repository.suspended, !workspace.gitCommands.loading,
      !workspace.gitRefreshing, !workspace.gitBusy, !workspace.gitActionRunning,
      !workspace.generatingCommitMessage, !workspace.pullRequestDraft.creating,
      workspace.gitRoot == request.repository.root, workspace.gitAvailable, workspace.canCommit,
      workspace.canModifyReview, !store.library.gitPreferences.readOnlyReview,
      !workspace.showingCommitPush, !workspace.showingPullRequest,
      !workspace.pullRequestDraft.modalActionPending,
      let value = workspace.gitCommands.snapshot else { return false }
    if let taskID {
      guard let task = store.library.tasks.first(where: { $0.id == taskID }),
        let project = workspace.root, !task.project.isEmpty,
        GitBranchService.canonicalRoot(URL(fileURLWithPath: task.project))
          == GitBranchService.canonicalRoot(project) else { return false }
    }
    if id == "git.commit" { return value.canCommit || value.canPush }
    return value.pullRequest?.blockedReason(includeLocalChanges: true) == nil
      && value.pullRequest != nil
  }
  var error: String? { workspace.gitCommands.error ?? workspace.gitCommands.snapshot?.pullRequestError }
  var loading: Bool { workspace.gitCommands.loading }
  func refresh() async {
    guard available(), currentTaskID.map({ $0() == taskID }) ?? true,
      workspace.generationForGitMutation == request.repository.generation,
      workspace.reviewRepositoryEpoch == request.repository.epoch,
      workspace.reviewSnapshot == request.repository.revision else { return }
    let draft = workspace.pullRequestDraft
    await workspace.gitCommands.load(request) { root, primary in
      try await GitWorkflowCommandSnapshot.capture(at: root, primary: primary) {
        try await draft.inspectEntry(at: $0)
      }
    }
  }
  func command(for binding: ShortcutBinding, shortcuts: ShortcutPreferences) -> String? {
    Self.ids.first { shortcuts.matches($0, binding) && enabled($0) }
  }
  @discardableResult func execute(_ id: String) -> Bool {
    guard enabled(id) else { return false }
    workspace.presentGitOptions(taskID: taskID,
      pullRequest: id != "git.commit", forceDraft: id == "git.createDraftPullRequest")
    return true
  }
}

private struct GitWorkflowCommandsKey: FocusedValueKey { typealias Value = GitWorkflowCommandContext }
extension FocusedValues {
  var gitWorkflowCommands: GitWorkflowCommandContext? {
    get { self[GitWorkflowCommandsKey.self] }
    set { self[GitWorkflowCommandsKey.self] = newValue }
  }
}

extension DeveloperWorkspace {
  func presentGitOptions(taskID: String?, pullRequest: Bool, forceDraft: Bool = false) {
    guard !showingCommitPush, !showingPullRequest, !gitActionRunning, !gitBusy,
      !pullRequestDraft.creating, !pullRequestDraft.modalActionPending else { return }
    gitPresentationTaskID = taskID
    gitPresentationForceDraft = pullRequest && forceDraft
    if pullRequest { showingPullRequest = true } else { showingCommitPush = true }
  }
  func clearGitPresentation() {
    guard !showingCommitPush, !showingPullRequest else { return }
    gitPresentationTaskID = nil; gitPresentationForceDraft = false
  }
}
