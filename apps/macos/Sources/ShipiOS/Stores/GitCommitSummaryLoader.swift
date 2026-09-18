import Foundation
import Observation

struct GitCommitSummaryRequest: Equatable {
  let root: URL?
  let includeUnstaged: Bool
  let revision: UUID
}

@MainActor @Observable final class GitCommitSummaryLoader {
  private(set) var request: GitCommitSummaryRequest?
  private(set) var summary: GitCommitSummary?
  private(set) var error: String?
  private(set) var loading = false
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private let read: (URL, Bool) async throws -> GitCommitSummary

  init(read: @escaping (URL, Bool) async throws -> GitCommitSummary = {
    try await GitCommitSummary.capture(at: $0, includeUnstaged: $1)
  }) { self.read = read }

  func load(_ request: GitCommitSummaryRequest) async {
    let operation = UUID()
    token = operation; self.request = request
    summary = nil; error = nil; loading = true
    defer { if token == operation { loading = false } }
    guard let root = request.root else { error = "当前任务没有 Git 项目。"; return }
    do {
      let value = try await read(root, request.includeUnstaged)
      guard token == operation, !Task.isCancelled else { return }
      summary = value
    } catch {
      if token == operation, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
