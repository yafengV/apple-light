import Foundation

extension DeveloperWorkspace {
  func stageAll(_ snapshot: GitBatchSnapshot) async {
    guard root == snapshot.root, reviewScope == snapshot.scope, canModifyReview,
      !gitBusy, !reviewLoading, !gitRefreshing
    else { return }
    let operation = generationForGitMutation
    gitBusy = true
    error = nil
    defer { if generationForGitMutation == operation { gitBusy = false } }
    do {
      try await GitBatchService.apply(snapshot, authorize: gitMutationAuthorization(at: snapshot.root))
      if root == snapshot.root, generationForGitMutation == operation { await refreshGit() }
    } catch {
      if root == snapshot.root, generationForGitMutation == operation, !(error is CancellationError) {
        self.error = error.localizedDescription
        batchSnapshot = nil
      }
    }
  }
}
