import Foundation

extension WorkspaceStore {
  func bindGitReviewPolicy(to workspace: DeveloperWorkspace) {
    workspace.isGitReviewReadOnly = { [weak self] in
      self?.library.gitPreferences.readOnlyReview != false
    }
  }
}

extension DeveloperWorkspace {
  var canModifyReview: Bool { !isGitReviewReadOnly() && !reviewScope.isHistorical }

  func gitMutationAuthorization(at project: URL) -> GitMutationAuthorization {
    let token = generationForGitMutation, scope = reviewScope
    return { [weak self] in
      try Task.checkCancellation()
      guard let self, self.root == project, self.generationForGitMutation == token,
        self.reviewScope == scope else { throw CancellationError() }
      guard self.canModifyReview else {
        throw AgentFailure(message: "当前审查为只读，未执行仓库修改。")
      }
    }
  }
}
