import Foundation

extension DeveloperWorkspace {
  var canInitializeGit: Bool {
    root != nil && !gitAvailable && !isGitReviewReadOnly() && !gitBusy
      && !gitRefreshing && !gitActionRunning && !generatingCommitMessage
  }

  @discardableResult
  func initializeGit(at project: URL) async -> Bool {
    guard root == project, canInitializeGit else { return false }
    let operation = generationForGitMutation
    gitBusy = true
    error = nil
    gitActionStatus = nil
    defer { if generationForGitMutation == operation { gitBusy = false } }
    do {
      try await GitInitializationService.initialize(at: project) { [weak self] in
        try Task.checkCancellation()
        guard let self, self.root == project, self.generationForGitMutation == operation else {
          throw CancellationError()
        }
        guard !self.isGitReviewReadOnly() else {
          throw AgentFailure(message: "当前审查为只读，未创建 Git 仓库。")
        }
      }
      guard root == project, generationForGitMutation == operation else { return false }
      reviewScope = .unstaged
      await refreshGit()
      guard root == project, generationForGitMutation == operation else { return false }
      await refreshFiles()
      guard root == project, generationForGitMutation == operation else { return false }
      gitActionStatus = "已创建 Git 仓库"
      return gitAvailable
    } catch {
      guard root == project, generationForGitMutation == operation, !(error is CancellationError) else {
        return false
      }
      // A repository may have appeared while preflight was in progress. Refresh
      // it without reinitializing, and keep the original failure available.
      let message = error.localizedDescription
      await refreshGit()
      if root == project, generationForGitMutation == operation { self.error = message }
      return false
    }
  }
}
