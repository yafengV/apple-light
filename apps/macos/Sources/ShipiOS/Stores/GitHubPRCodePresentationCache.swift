import Foundation

struct GitHubPRCodePresentation {
  let query: String
  let showsFiles: Bool
  let selectedPath: String?
  let scrollOffset: Double
}

/// Keeps one PR's navigation state while its content tab is absent from the view tree.
@MainActor final class GitHubPRCodePresentationCache {
  private struct Key: Hashable {
    let taskID: String
    let root: String
    let url: String
    let number: Int
    let head: String
    let headBranch: String
    let baseBranch: String

    init(_ request: GitHubPRCodeRequest) {
      taskID = request.taskID
      root = request.root.standardizedFileURL.path
      url = request.pullRequest.validatedURL?.absoluteString ?? request.pullRequest.url
      number = request.pullRequest.number
      head = request.head.lowercased()
      headBranch = request.pullRequest.headRefName
      baseBranch = request.pullRequest.baseRefName
    }
  }

  private var values: [Key: GitHubPRCodePresentation] = [:]
  private var recent: [Key] = []
  private let limit = 64

  func save(_ request: GitHubPRCodeRequest, from state: GitHubPRCodeState) {
    guard state.snapshot?.identity.head.lowercased() == request.head.lowercased() else { return }
    let key = Key(request)
    values[key] = state.presentation
    recent.removeAll { $0 == key }
    recent.append(key)
    if recent.count > limit {
      let removed = recent.removeFirst()
      values.removeValue(forKey: removed)
    }
  }

  func restore(_ request: GitHubPRCodeRequest, into state: GitHubPRCodeState) {
    guard let value = values[Key(request)],
      state.snapshot?.identity.head.lowercased() == request.head.lowercased() else { return }
    state.restorePresentation(value)
  }
}
