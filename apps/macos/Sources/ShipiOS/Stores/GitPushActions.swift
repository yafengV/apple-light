import Foundation

extension DeveloperWorkspace {
  @discardableResult func push(remote: String, destination: String, forceWithLease: Bool) async -> Bool {
    guard let root = gitRoot, canCommit, !gitBusy, canModifyReview else { return false }
    let token = UUID()
    pushOperation = token
    gitBusy = true
    error = nil
    defer { if pushOperation == token { gitBusy = false; pushOperation = nil } }
    do {
      let plan = try await GitPushService.prepare(at: root, remote: remote,
        destination: destination, forceWithLease: forceWithLease)
      guard gitRoot == root, pushOperation == token else { return false }
      let warning = try await GitPushService.push(plan, authorize: gitMutationAuthorization(at: root))
      guard gitRoot == root, pushOperation == token else { return false }
      gitActionStatus = warning ?? "已推送 \(plan.branch) → \(plan.remote)/\(destination)"
      await refreshGit()
      return true
    } catch {
      if gitRoot == root, pushOperation == token { self.error = error.localizedDescription }
      return false
    }
  }
}
