import Foundation
import Observation

/// Opening a linked PR does not mutate Git or inherit commit eligibility.
@MainActor @Observable final class GitPullRequestLinkOpening {
  private(set) var opening = false
  private(set) var error: String?
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private(set) var operation: Task<Void, Never>?

  @discardableResult func start(_ url: URL, valid: @escaping @MainActor () -> Bool,
    failed: @escaping @MainActor () -> Void = {},
    open: @escaping @MainActor (URL) async -> Bool) -> Bool {
    guard !opening, valid() else { return false }
    let request = UUID(); token = request; opening = true; error = nil
    operation = Task { [weak self] in
      guard let self else { return }
      defer { if token == request { opening = false; operation = nil } }
      guard token == request, !Task.isCancelled, valid() else { return }
      let accepted = await open(url)
      guard token == request, !Task.isCancelled, valid() else { return }
      if !accepted { error = "无法打开 PR 链接，请重试。"; failed() }
    }
    return true
  }
  func cancel() {
    token = UUID(); operation?.cancel(); operation = nil; opening = false; error = nil
  }
}
