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

  func gitMutationAuthorization(at repository: URL) -> GitMutationAuthorization {
    let authorizeContext = gitRepositoryAuthorization(at: repository), scope = reviewScope
    return { [weak self] in
      try authorizeContext()
      guard let self, self.reviewScope == scope else { throw CancellationError() }
      guard self.canModifyReview else {
        throw AgentFailure(message: "当前审查为只读，未执行仓库修改。")
      }
    }
  }

  func gitRepositoryAuthorization(at repository: URL) -> GitMutationAuthorization {
    let token = generationForGitMutation
    let project = root
    return { [weak self] in
      try Task.checkCancellation()
      guard let self, self.root == project, self.generationForGitMutation == token,
        self.gitRoot.map(GitBranchService.canonicalRoot)?.path
          == GitBranchService.canonicalRoot(repository).path else { throw CancellationError() }
      if self.gitRepositoryRoot != nil, let project {
        guard try GitRepositoryContext.candidate(at: project)?.path
          == GitBranchService.canonicalRoot(repository).path else { throw CancellationError() }
      }
    }
  }
}
