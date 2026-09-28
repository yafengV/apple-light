import Foundation
import Observation

/// A confirmation request is local to a live window and is never restored from disk.
@MainActor @Observable final class PullRequestTabPresentations {
  private var confirmations: [String: UUID] = [:]
  func request(_ id: String) { confirmations[id] = UUID() }
  func token(_ id: String) -> UUID? { confirmations[id] }
  func consume(_ id: String, token: UUID) {
    if confirmations[id] == token { confirmations[id] = nil }
  }
  func clear(_ id: String) { confirmations[id] = nil }
}

extension WorkspaceStore {
  @discardableResult func preparePullRequestContent(_ request: GitHubPullRequest, taskID: String) -> Bool {
    guard !restoringLibrary, !shuttingDown,
      let task = library.tasks.first(where: { $0.id == taskID }), !task.project.isEmpty,
      let url = request.validatedURL else { return false }
    if library.taskPullRequests[taskID]?.contains(where: { $0.url == request.url }) == true { return true }
    let parts = url.pathComponents
    guard let repo = try? GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])") else { return false }
    return recordPullRequest(request, for: taskID, at: URL(fileURLWithPath: task.project), repository: repo)
  }
  func pullRequestContent(_ tab: WorkspaceContentTab) -> GitHubPullRequest? {
    guard let url = tab.pullRequestURL,
      library.tasks.contains(where: { $0.id == tab.owner && !$0.project.isEmpty }) else { return nil }
    return library.taskPullRequests[tab.owner]?.first { $0.url == url && $0.validatedURL != nil }
  }

  /// Reuses the same PR within this task. Existing panel placement is preserved.
  @discardableResult func openPullRequestContent(_ request: GitHubPullRequest,
    in placement: WorkspaceTabPlacement = .right, mergeConfirmation: Bool = false) -> Bool {
    let tab = WorkspaceContentTab.pullRequest(request.url, owner: currentWorkspaceTabOwner)
    guard placement == .left || placement == .right, !restoringLibrary, !shuttingDown, pullRequestContent(tab) != nil else { return false }
    if !workspaceTabs.contains(tab) {
      workspaceTabs.append(tab); workspaceTabPlacements[tab.id] = placement
    }
    if mergeConfirmation { pullRequestTabPresentations.request(tab.id) }
    activateWorkspaceTab(tab.id)
    return true
  }

  /// Detached windows route explicitly to the owning task rather than main selection.
  @discardableResult func openPullRequestContent(_ request: GitHubPullRequest,
    taskID: String, mergeConfirmation: Bool) async -> Bool {
    guard let task = library.tasks.first(where: { $0.id == taskID }), !task.project.isEmpty,
      canSelectTask(task), request.validatedURL != nil else { return false }
    let project = task.project
    if currentProjectKey != project { guard await openTaskScope(project) else { return false } }
    guard !Task.isCancelled, let current = library.tasks.first(where: { $0.id == taskID && $0.project == project }),
      canSelectTask(current), preparePullRequestContent(request, taskID: taskID) else { return false }
    if currentWorkspaceTabOwner != taskID { applyTaskSelection(current) }
    return openPullRequestContent(request, mergeConfirmation: mergeConfirmation)
  }
}
