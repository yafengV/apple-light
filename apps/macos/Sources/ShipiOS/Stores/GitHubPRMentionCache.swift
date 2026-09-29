import Foundation

/// Matches the one-minute query freshness window without persisting account data.
@MainActor final class GitHubPRMentionCache {
  static let shared = GitHubPRMentionCache()
  private struct Entry { let users: [GitHubPRMentionUser]; let date: Date }
  private struct Pending {
    let id: UUID
    let task: Task<[GitHubPRMentionUser], Error>
    var waiters: Set<UUID>
  }
  private var entries: [String: Entry] = [:]
  private var pending: [String: Pending] = [:]
  private let now: () -> Date
  init(now: @escaping () -> Date = Date.init) { self.now = now }
  private func key(_ context: GitHubPRMentionRequest, _ query: String, _ service: GitHubPRService) -> String {
    context.scope + "\n" + (service.executable?.standardizedFileURL.path ?? "installed") + "\n" + query
  }
  func fresh(_ context: GitHubPRMentionRequest, query: String, service: GitHubPRService) -> [GitHubPRMentionUser]? {
    let key = key(context, query, service)
    guard let entry = entries[key], now().timeIntervalSince(entry.date) < 60 else { entries[key] = nil; return nil }
    return entry.users
  }
  func users(_ context: GitHubPRMentionRequest, query: String, service: GitHubPRService) async throws -> [GitHubPRMentionUser] {
    try Task.checkCancellation()
    if let users = fresh(context, query: query, service: service) { return users }
    let key = key(context, query, service), waiter = UUID()
    let entry: Pending
    if var existing = pending[key] { existing.waiters.insert(waiter); pending[key] = existing; entry = existing }
    else {
      entry = Pending(id: UUID(), task: Task { try await service.mentionUsers(context, query: query) }, waiters: [waiter])
      pending[key] = entry
    }
    return try await withTaskCancellationHandler {
      defer { release(key, id: entry.id, waiter: waiter) }
      let result = try await entry.task.value
      try Task.checkCancellation()
      if pending[key]?.id == entry.id {
        let date = now()
        entries = entries.filter { date.timeIntervalSince($0.value.date) < 60 }
        if entries.count >= 256, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key { entries[oldest] = nil }
        entries[key] = Entry(users: result, date: date)
      }
      return result
    } onCancel: {
      Task { @MainActor [weak self] in self?.release(key, id: entry.id, waiter: waiter) }
    }
  }
  private func release(_ key: String, id: UUID, waiter: UUID) {
    guard var entry = pending[key], entry.id == id else { return }
    entry.waiters.remove(waiter)
    if entry.waiters.isEmpty { pending[key] = nil; entry.task.cancel() }
    else { pending[key] = entry }
  }
}
