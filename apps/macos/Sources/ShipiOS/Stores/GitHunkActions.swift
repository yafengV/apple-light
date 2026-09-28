import Foundation

extension DeveloperWorkspace {
  func applyHunk(
    _ action: GitHunkAction, file: GitFile, hunk: ReviewHunk, snapshot: ReviewDiff, project: URL
  ) async {
    guard gitRoot == project, reviewScope == action.scope, !gitBusy, canModifyReview else { return }
    let operation = generationForGitMutation
    gitBusy = true
    error = nil
    defer { if generationForGitMutation == operation { gitBusy = false } }
    do {
      try await GitHunkService.apply(
        action, path: file.path, hunkID: hunk.id, snapshot: snapshot, at: project, authorize: gitMutationAuthorization(at: project))
      if gitRoot == project, generationForGitMutation == operation { await refreshGit() }
    } catch { if gitRoot == project, generationForGitMutation == operation, !(error is CancellationError) { self.error = error.localizedDescription } }
  }
}
