import Foundation
import Observation

@MainActor @Observable
final class GitBranchCatalog {
  private(set) var snapshot: GitBranchSnapshot?
  private(set) var loading = false
  private(set) var error: String?
  private var generation = UUID()

  func load(root: URL, read: (URL) async throws -> GitBranchSnapshot = { try await GitBranchService.snapshot(at: $0) }) async {
    let token = UUID()
    generation = token
    loading = true
    snapshot = nil
    error = nil
    defer { if generation == token { loading = false } }
    do {
      let result = try await read(root)
      guard generation == token, !Task.isCancelled else { return }
      snapshot = result
    } catch {
      if generation == token, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
