import Foundation

extension DeveloperWorkspace {
  func applyHunk(
    _ action: GitHunkAction, file: GitFile, hunk: ReviewHunk, snapshot: ReviewDiff, project: URL
  ) async {
    guard root == project, reviewScope == action.scope, !gitBusy else { return }
    gitBusy = true
    error = nil
    defer { gitBusy = false }
    do {
      try await GitHunkService.apply(
        action, path: file.path, hunkID: hunk.id, snapshot: snapshot, at: project)
      if root == project { await refreshGit() }
    } catch { if root == project { self.error = error.localizedDescription } }
  }
}
