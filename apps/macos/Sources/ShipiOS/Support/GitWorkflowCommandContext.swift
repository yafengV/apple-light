import SwiftUI

/// The focused window owns both metadata and presentation. No fallback to main selection.
@MainActor struct GitWorkflowCommandContext {
  static let ids = ["git.commit", "git.createPullRequest", "git.createDraftPullRequest", "git.createBranch", "git.openPullRequest", "git.mergePullRequest"]
  static func owns(_ id: String) -> Bool { ids.contains(id) }
  let store: WorkspaceStore
  let workspace: DeveloperWorkspace
  let taskID: String?
  let request: GitWorkflowCommandRequest
  let available: () -> Bool
  var currentTaskID: (() -> String?)? = nil
  var openPullRequestLink: (@MainActor (URL) async -> Bool)? = nil
  var selectedPullRequest: (() -> GitHubPullRequest?)? = nil
  var activePullRequestURLs: (() -> [String])? = nil
  var openPullRequestDetails: (@MainActor (GitHubPullRequest, Bool) async -> Bool)? = nil

  var linkedPullRequest: GitHubPullRequest? {
    guard let taskID, let task = store.library.tasks.first(where: { $0.id == taskID }) else { return nil }
    if let selectedPullRequest { if let selected = selectedPullRequest(), selected.validatedURL != nil { return selected } }
    else if let tab = [store.focusedWorkspaceContentTab, store.activeWorkspaceContentTab,
      store.activeRightWorkspaceContentTab].compactMap({ $0 }).first(where: { $0.owner == taskID && $0.kind == .pullRequest }),
      let selected = store.pullRequestContent(tab) { return selected }
    if request.primary, workspace.gitCommands.request == request,
      let existing = workspace.gitCommands.snapshot?.pullRequest?.context.existing,
      existing.validatedURL != nil { return existing }
    if request.primary, workspace.gitCommands.request == request,
      let known = workspace.gitCommands.retainedPullRequest,
      workspace.gitBranch.isEmpty || workspace.gitBranch == "detached HEAD" || workspace.gitBranch == known.plan.branch,
      let existing = known.existing, existing.validatedURL != nil { return existing }
    let head: String?
    if request.primary, workspace.gitCommands.request == request, let snapshot = workspace.gitCommands.snapshot {
      head = snapshot.branchName ?? task.gitBranch
    } else if request.primary {
      head = (workspace.gitBranch.isEmpty || workspace.gitBranch == "detached HEAD" ? nil : workspace.gitBranch) ?? task.gitBranch
    } else { head = task.gitBranch }
    return store.library.taskPullRequests[taskID]?.first {
      $0.validatedURL != nil && (head == nil || $0.headRefName == head)
    }
  }
  private var linkedPullRequestURL: URL? { linkedPullRequest?.validatedURL }
  var mergeRequest: GitPullRequestMergeCommandRequest? {
    guard let taskID, let root = workspace.root, let pullRequest = linkedPullRequest,
      !pullRequest.isDraft, pullRequest.state?.uppercased() != "MERGED" else { return nil }
    return .init(taskID: taskID, root: root, pullRequest: pullRequest,
      generation: request.repository.generation, epoch: request.repository.epoch)
  }
  private var mergeSnapshot: GitHubPRMergeSnapshot? {
    guard let mergeRequest, workspace.pullRequestMergeCommand.request == mergeRequest else { return nil }
    return workspace.pullRequestMergeCommand.snapshot
  }
  private var pullRequestTabSelected: Bool {
    guard let url = linkedPullRequest?.url else { return false }
    let selected = activePullRequestURLs?() ?? [store.activeWorkspaceContentTab?.pullRequestURL,
      store.activeRightWorkspaceContentTab?.pullRequestURL].compactMap { $0 }
    return selected.contains(url)
  }
  private func canOpenLinkedPullRequest(_ url: URL) -> Bool {
    guard available(), !store.restoringLibrary, !store.shuttingDown,
      currentTaskID.map({ $0() == taskID }) ?? true,
      workspace.generationForGitMutation == request.repository.generation,
      workspace.reviewRepositoryEpoch == request.repository.epoch,
      workspace.reviewSnapshot == request.repository.revision,
      !workspace.showingCommitPush, !workspace.showingPullRequest, !workspace.showingManagedBranchSetup,
      let taskID, let task = store.library.tasks.first(where: { $0.id == taskID }),
      task.project.isEmpty || workspace.root.map({ GitBranchService.canonicalRoot($0).path == GitBranchService.canonicalRoot(URL(fileURLWithPath: task.project)).path }) == true,
      linkedPullRequestURL == url else { return false }
    return true
  }

  private func canOpenMergeDetails(_ url: URL) -> Bool {
    visible("git.mergePullRequest") && canOpenLinkedPullRequest(url) && !store.library.gitPreferences.readOnlyReview
      && (!pullRequestTabSelected || (mergeSnapshot?.details.state.uppercased() == "OPEN"
        && mergeSnapshot?.isAutoMergeEnabled != true))
      && !GitHubPRActionCoordinator.shared.isBusy(url.absoluteString)
  }

  func visible(_ id: String) -> Bool {
    guard Self.owns(id) else { return false }
    if id == "git.openPullRequest" { return linkedPullRequestURL != nil }
    if id == "git.mergePullRequest" {
      return mergeSnapshot?.isAuthor == true && mergeSnapshot?.details.isDraft == false
        && mergeSnapshot?.details.state.uppercased() != "MERGED"
    }
    if id == "git.commit" { return true }
    if id == "git.createBranch" { return store.managedCheckout(in: workspace, taskID: taskID) != nil }
    return workspace.gitCommands.request == request && request.primary
      && workspace.gitCommands.snapshot?.showsPullRequest == true
  }
  func enabled(_ id: String) -> Bool {
    if id == "git.openPullRequest" {
      return linkedPullRequestURL.map(canOpenLinkedPullRequest) == true && !workspace.pullRequestLinkOpening.opening
    }
    if id == "git.mergePullRequest" {
      return linkedPullRequestURL.map(canOpenMergeDetails) == true && !workspace.pullRequestLinkOpening.opening
    }
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
      !workspace.showingCommitPush, !workspace.showingPullRequest, !workspace.showingManagedBranchSetup,
      !workspace.pullRequestDraft.modalActionPending,
      let value = workspace.gitCommands.snapshot else { return false }
    if let taskID {
      guard let task = store.library.tasks.first(where: { $0.id == taskID }),
        let project = workspace.root, !task.project.isEmpty,
        GitBranchService.canonicalRoot(URL(fileURLWithPath: task.project))
          == GitBranchService.canonicalRoot(project) else { return false }
    }
    if id == "git.createBranch" { return true }
    if id == "git.commit" { return value.canCommit || value.canPush }
    return value.pullRequest?.blockedReason(includeLocalChanges: true) == nil
      && value.pullRequest != nil
  }
  var error: String? { workspace.pullRequestLinkOpening.error ?? workspace.gitCommands.error ?? workspace.gitCommands.snapshot?.pullRequestError ?? workspace.pullRequestMergeCommand.error }
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
    await workspace.pullRequestMergeCommand.load(mergeRequest)
  }
  func command(for binding: ShortcutBinding, shortcuts: ShortcutPreferences) -> String? {
    Self.ids.first { shortcuts.matches($0, binding) && enabled($0) }
  }
  @discardableResult func execute(_ id: String) -> Bool {
    guard enabled(id) else { return false }
    if id == "git.mergePullRequest", let pr = linkedPullRequest, let url = pr.validatedURL, let taskID {
      return workspace.pullRequestLinkOpening.start(url, valid: { canOpenMergeDetails(url) }, failed: {
        store.notices.show(id: "pr-detail-" + taskID, title: "无法打开 PR 详情，请重试。", level: .error, taskID: taskID)
      }) { _ in
        if let openPullRequestDetails { return await openPullRequestDetails(pr, true) }
        return await store.openPullRequestContent(pr, taskID: taskID, mergeConfirmation: true)
      }
    }
    if id == "git.openPullRequest", let url = linkedPullRequestURL, let taskID {
      return workspace.pullRequestLinkOpening.start(url, valid: { canOpenLinkedPullRequest(url) }, failed: {
        store.notices.show(id: "pr-link-" + taskID, title: "无法打开 PR 链接，请重试。", level: .error, taskID: taskID)
      }) { url in
        if let openPullRequestLink { return await openPullRequestLink(url) }
        return await store.openTaskWebLink(url, taskID: taskID)
      }
    }
    if id == "git.createBranch" { return store.presentManagedBranchSetup(in: workspace, taskID: taskID) }
    if id == "git.commit", let value = workspace.gitCommands.snapshot, !value.canCommit,
      store.managedCheckout(in: workspace, taskID: taskID) != nil,
      value.branchName == nil || value.branchName == value.defaultBranch {
      return store.presentManagedBranchSetup(in: workspace, taskID: taskID, next: .commit)
    }
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
    guard !showingCommitPush, !showingPullRequest, !showingManagedBranchSetup, !gitActionRunning, !gitBusy,
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
