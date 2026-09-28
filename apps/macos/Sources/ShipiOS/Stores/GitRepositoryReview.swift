import Foundation

extension DeveloperWorkspace {
  func modelReviewSnapshot(scope: ModelCodeReviewScope) async throws -> ModelCodeReviewSnapshot {
    guard let project = root, let repository = gitRoot else {
      throw AgentFailure(message: "请先打开 Git 项目。")
    }
    let generation = generationForGitMutation
    let epoch = reviewRepositoryEpoch
    var snapshot = try await GitReviewService.modelReviewSnapshot(scope: scope, at: repository)
    guard root == project, gitRoot == repository, generationForGitMutation == generation,
      reviewRepositoryEpoch == epoch else {
      throw CancellationError()
    }
    if GitBranchService.canonicalRoot(repository).path != GitBranchService.canonicalRoot(project).path {
      snapshot.repositoryRoot = GitBranchService.canonicalRoot(repository).path
    }
    return snapshot
  }
}
