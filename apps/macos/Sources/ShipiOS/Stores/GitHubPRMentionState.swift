import Foundation
import Observation

@MainActor @Observable final class GitHubPRMentionState {
  private(set) var token: GitHubPRMentionToken?
  private(set) var users: [GitHubPRMentionUser] = []
  private(set) var highlighted = -1
  private(set) var loading = false
  private(set) var error: String?
  private(set) var replacement: PullRequestTextReplacement?
  @ObservationIgnored private var context: GitHubPRMentionRequest?
  @ObservationIgnored private var base: [GitHubPRMentionUser]?
  @ObservationIgnored private var baseError: String?
  @ObservationIgnored private var baseLoading = false
  @ObservationIgnored private var searched: [GitHubPRMentionUser]?
  @ObservationIgnored private var searchedQuery: String?
  @ObservationIgnored private var dismissed: GitHubPRMentionToken?
  @ObservationIgnored private var document = ""
  @ObservationIgnored private var revision = UUID()
  @ObservationIgnored private var searchRevision = UUID()
  @ObservationIgnored private(set) var baseTask: Task<Void, Never>?
  @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
  @ObservationIgnored private let service: GitHubPRService
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private let cache: GitHubPRMentionCache
  init(service: GitHubPRService = .init(), debounce: Duration = .milliseconds(500), cache: GitHubPRMentionCache? = nil) {
    self.service = service; self.debounce = debounce; self.cache = cache ?? .shared
  }
  var visible: Bool { token != nil && (token?.query.count != 1 || !users.isEmpty) }

  func setContext(_ next: GitHubPRMentionRequest?) {
    guard context?.scope != next?.scope else { return }
    cancel(); context = next; base = nil; baseError = nil; searched = nil; searchedQuery = nil
  }
  func select(text: String, range: NSRange) {
    document = text
    guard context != nil, let found = GitHubPRMentionToken.detect(text: text, selection: range) else {
      dismissed = nil; hide(); return
    }
    if let dismissed, found.range.location == dismissed.range.location, found.query.hasPrefix(dismissed.query) {
      hide(); return
    }
    dismissed = nil
    if token == nil, let context {
      base = cache.fresh(context, query: "", service: service); baseError = nil
    }
    let changedQuery = token?.query != found.query
    token = found
    if changedQuery { searched = nil; searchedQuery = nil; error = nil; highlighted = -1 }
    if base == nil, !baseLoading { loadBase() }
    if changedQuery { search(found.query) }
    updateCandidates()
  }
  func dismiss() {
    dismissed = token; hide()
  }
  func blurred() { hide() }
  func highlight(_ index: Int) { if users.indices.contains(index) { highlighted = index } }
  func move(_ delta: Int) {
    guard visible, !users.isEmpty else { return }
    if highlighted < 0 { highlighted = delta > 0 ? 0 : users.count - 1 }
    else { highlighted = (highlighted + delta + users.count) % users.count }
  }
  @discardableResult func choose(_ index: Int? = nil) -> Bool {
    let index = index ?? highlighted
    guard visible, users.indices.contains(index), let token,
      let replacement = token.replacement(login: users[index].login, in: document) else { return false }
    self.replacement = replacement
    dismissed = .init(range: .init(location: token.range.location, length: users[index].login.utf16.count + 1), query: users[index].login)
    hide(); return true
  }
  private func hide() {
    token = nil; users = []; highlighted = -1; loading = false; error = nil
    searchRevision = UUID(); searchTask?.cancel(); searchTask = nil
  }
  func cancel() {
    revision = UUID(); baseTask?.cancel(); baseTask = nil; baseLoading = false
    dismissed = nil; replacement = nil; hide()
  }
  private func loadBase() {
    guard let context else { return }
    let owner = revision
    baseLoading = true
    baseTask = Task {
      defer { if owner == revision { baseLoading = false; baseTask = nil; updateCandidates() } }
      do {
        let result = try await cache.users(context, query: "", service: service)
        guard !Task.isCancelled, revision == owner, self.context?.scope == context.scope else { return }
        base = result; baseError = nil
      } catch {
        guard !Task.isCancelled, revision == owner else { return }
        base = []; baseError = error.localizedDescription
      }
    }
  }
  private func search(_ query: String) {
    searchRevision = UUID(); searchTask?.cancel(); searchTask = nil
    guard query.count >= 2, let context else { return }
    let owner = revision, searchID = searchRevision
    loading = true
    searchTask = Task {
      defer { if owner == revision, searchID == searchRevision { searchTask = nil; updateCandidates() } }
      do {
        try await Task.sleep(for: debounce)
        let result = try await cache.users(context, query: query, service: service)
        guard !Task.isCancelled, owner == revision, searchID == searchRevision, token?.query == query else { return }
        searched = result; searchedQuery = query; error = nil
      } catch {
        guard !Task.isCancelled, owner == revision, searchID == searchRevision, token?.query == query else { return }
        searched = []; searchedQuery = query; self.error = error.localizedDescription
      }
    }
  }
  private func updateCandidates() {
    guard let token else { return }
    let oldSelection = users.indices.contains(highlighted) ? users[highlighted].id : nil
    var seen: Set<String> = []
    users = Array(((base ?? []).filter { token.query.isEmpty || $0.login.lowercased().contains(token.query.lowercased()) }
      + (searchedQuery == token.query ? searched ?? [] : [])).filter { seen.insert($0.id).inserted }.prefix(10))
    if let oldSelection { highlighted = users.firstIndex { $0.id == oldSelection } ?? (users.isEmpty ? -1 : 0) }
    else if !users.indices.contains(highlighted) { highlighted = users.isEmpty ? -1 : 0 }
    loading = baseLoading || token.query.count >= 2 && searchedQuery != token.query
    if error == nil { error = baseError }
  }
}
