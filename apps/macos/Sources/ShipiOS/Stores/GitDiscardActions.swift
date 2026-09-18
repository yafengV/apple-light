import Foundation

extension DeveloperWorkspace {
  func prepareDiscard(_ snapshot: GitBatchSnapshot, path: String? = nil) async {
    guard root == snapshot.root, reviewScope == .unstaged, !gitBusy else { return }
    gitBusy = true
    error = nil
    defer { gitBusy = false }
    do {
      let plan = try await GitDiscardService.prepare(snapshot, selectedPath: path)
      if root == snapshot.root, reviewScope == .unstaged { discardPlan = plan }
    } catch { if root == snapshot.root { self.error = error.localizedDescription } }
  }
  func discard(_ plan: GitDiscardPlan) async {
    guard root == plan.snapshot.root, reviewScope == .unstaged, !gitBusy else { return }
    discardPlan = nil
    gitBusy = true
    error = nil
    defer { gitBusy = false }
    var failure: String?
    do { try await GitDiscardService.execute(plan) } catch { failure = error.localizedDescription }
    if root == plan.snapshot.root {
      await refreshGit()
      if let failure { error = failure }
    }
  }
}
