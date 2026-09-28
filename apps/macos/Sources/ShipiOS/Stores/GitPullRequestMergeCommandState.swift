import Foundation
import Observation

struct GitPullRequestMergeCommandRequest: Equatable {
  let taskID: String
  let root: URL
  let pullRequest: GitHubPullRequest
  let generation: UUID
  let epoch: UUID
}

@MainActor @Observable final class GitPullRequestMergeCommandState {
  private(set) var request: GitPullRequestMergeCommandRequest?
  private(set) var snapshot: GitHubPRMergeSnapshot?
  private(set) var loading = false
  private(set) var error: String?
  @ObservationIgnored private var token = UUID()

  func load(_ request: GitPullRequestMergeCommandRequest?,
    read: (GitHubPullRequest, URL) async throws -> GitHubPRMergeSnapshot = {
      try await GitHubPRService().mergeSnapshot(for: $0, at: $1)
    }) async {
    let operation = UUID(); token = operation; self.request = request
    snapshot = nil; loading = false; error = nil
    guard let request else { return }
    loading = true
    defer { if token == operation { loading = false } }
    do {
      let value = try await read(request.pullRequest, request.root)
      guard !Task.isCancelled, token == operation else { return }
      snapshot = value
    } catch {
      guard !Task.isCancelled, token == operation else { return }
      self.error = error.localizedDescription
    }
  }
  func cancel() { token = UUID(); request = nil; snapshot = nil; error = nil; loading = false }
}
