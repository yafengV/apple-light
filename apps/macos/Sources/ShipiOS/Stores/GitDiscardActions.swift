import Foundation

extension DeveloperWorkspace {
  func prepareDiscard(_ snapshot: GitBatchSnapshot, path: String? = nil) async {
    guard gitRoot == snapshot.root, reviewScope == .unstaged, !gitBusy, canModifyReview else { return }
    let operation = generationForGitMutation
    gitBusy = true
    error = nil
    defer { if generationForGitMutation == operation { gitBusy = false } }
    do {
      let plan = try await GitDiscardService.prepare(snapshot, selectedPath: path)
      if gitRoot == snapshot.root, generationForGitMutation == operation, reviewScope == .unstaged, canModifyReview { discardPlan = plan }
    } catch { if gitRoot == snapshot.root, generationForGitMutation == operation, !(error is CancellationError) { self.error = error.localizedDescription } }
  }
  func discard(_ plan: GitDiscardPlan) async {
    guard gitRoot == plan.snapshot.root, reviewScope == .unstaged, !gitBusy, canModifyReview else { return }
    discardPlan = nil
    let operation = generationForGitMutation
    gitBusy = true
    error = nil
    defer { if generationForGitMutation == operation { gitBusy = false } }
    var failure: String?
    do { try await GitDiscardService.execute(plan, authorize: gitMutationAuthorization(at: plan.snapshot.root)) } catch { failure = error.localizedDescription }
    if gitRoot == plan.snapshot.root, generationForGitMutation == operation {
      await refreshGit()
      if let failure { error = failure }
    }
  }
}
