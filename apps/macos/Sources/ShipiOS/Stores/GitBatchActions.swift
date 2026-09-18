import Foundation

extension DeveloperWorkspace {
  func stageAll(_ snapshot: GitBatchSnapshot) async {
    guard root == snapshot.root, reviewScope == snapshot.scope, !reviewScope.isHistorical,
      !gitBusy, !reviewLoading, !gitRefreshing
    else { return }
    gitBusy = true
    error = nil
    defer { gitBusy = false }
    do {
      try await GitBatchService.apply(snapshot)
      if root == snapshot.root { await refreshGit() }
    } catch {
      if root == snapshot.root {
        self.error = error.localizedDescription
        batchSnapshot = nil
      }
    }
  }
}
