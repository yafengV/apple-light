import Foundation
import Observation

@MainActor @Observable final class GitHubPRChecksState {
  private(set) var request: GitHubPRChecksRequest?
  private(set) var snapshot: GitHubPRChecksSnapshot?
  private(set) var loading = false
  private(set) var requiresPullRequestRefresh = false
  private(set) var error: String?
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private let service: GitHubPRService

  init(service: GitHubPRService = GitHubPRService()) { self.service = service }

  func load(_ request: GitHubPRChecksRequest?, valid: @escaping @MainActor () -> Bool,
    read: ((GitHubPRChecksRequest) async throws -> GitHubPRChecksSnapshot)? = nil) async {
    let operation = UUID(); token = operation; self.request = request
    snapshot = nil; error = nil; loading = false; requiresPullRequestRefresh = false
    guard let request, valid() else { return }
    loading = true
    defer { if token == operation { loading = false } }
    do {
      let result: GitHubPRChecksSnapshot
      if let read { result = try await read(request) } else { result = try await service.checks(request) }
      guard !Task.isCancelled, token == operation, valid() else { return }
      guard result.headRevision.lowercased() == request.headRevision.lowercased() else {
        throw GitHubPRRefreshRequired(message: "检查结果不属于当前 PR 头提交，请刷新后重试。")
      }
      snapshot = result
    } catch {
      guard !Task.isCancelled, token == operation, valid() else { return }
      requiresPullRequestRefresh = error is GitHubPRRefreshRequired
      self.error = error.localizedDescription
    }
  }
  func cancel() { token = UUID(); request = nil; snapshot = nil; error = nil; loading = false; requiresPullRequestRefresh = false }
}
