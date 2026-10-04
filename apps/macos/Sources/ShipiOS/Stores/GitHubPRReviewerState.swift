import Foundation
import Observation

@MainActor @Observable final class GitHubPRReviewerState {
  private(set) var snapshot: GitHubPRReviewersSnapshot?
  private(set) var loading = false
  private(set) var busy = false
  private(set) var error: String?
  private(set) var requiresRefresh = false
  var showingPicker = false
  private(set) var query = ""
  private(set) var searching = false
  private(set) var searchError: String?
  private(set) var selected: [GitHubPRMentionUser] = []
  private(set) var candidates: [GitHubPRMentionUser] = []
  var highlighted: String?
  @ObservationIgnored private let service: GitHubPRService
  @ObservationIgnored private let coordinator: GitHubPRActionCoordinator
  @ObservationIgnored private let debounce: Duration
  @ObservationIgnored private var loadToken: UUID?
  @ObservationIgnored private var searchToken: UUID?
  @ObservationIgnored private var mutationToken: UUID?
  @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
  @ObservationIgnored private(set) var operation: Task<Void, Never>?

  init(service: GitHubPRService = .init(), coordinator: GitHubPRActionCoordinator? = nil,
    debounce: Duration = .milliseconds(250)) {
    self.service = service; self.coordinator = coordinator ?? .shared; self.debounce = debounce
  }
  func canManage(_ request: GitHubPullRequest, writable: Bool) -> Bool {
    writable && snapshot?.requestURL.lowercased() == request.url.lowercased() && snapshot?.canManage == true
      && !loading && !busy && !requiresRefresh && !coordinator.isBusy(request.url)
  }

  var options: [GitHubPRReviewer] {
    guard !searching, searchError == nil else { return [] }
    var items = snapshot?.reviewers ?? [], seen = Set(items.map(\.id))
    let pending = Set(items.filter(\.requested).map(\.id))
    for user in selected + candidates {
      let item = GitHubPRReviewer(kind: .user, label: user.login, avatarURL: user.avatarURL)
      if !pending.contains(item.id), seen.insert(item.id).inserted { items.append(item) }
    }
    return items
  }
  func isSelected(_ reviewer: GitHubPRReviewer) -> Bool {
    snapshot?.reviewers.contains(where: { $0.id == reviewer.id }) == true
      || selected.contains(where: { "user:" + $0.id == reviewer.id })
  }

  func load(_ request: GitHubPullRequest, at root: URL, valid: @escaping @MainActor () -> Bool) async {
    guard valid(), !busy else { return }
    let token = UUID(); loadToken = token; loading = true
    defer { if loadToken == token { loading = false; loadToken = nil } }
    do {
      let result = try await service.reviewers(for: request, at: root)
      guard !Task.isCancelled, valid(), loadToken == token else { return }
      snapshot = result; error = nil; requiresRefresh = false
      if !result.canManage { closePicker() }
    } catch {
      guard !Task.isCancelled, valid(), loadToken == token else { return }
      self.error = error.localizedDescription
    }
  }

  func setQuery(_ text: String, request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool) {
    query = text; candidates = []; searchError = nil; searchTask?.cancel(); searchToken = nil
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let snapshot, valid(), showingPicker else {
      searching = false; highlighted = options.first?.id; return
    }
    let token = UUID(); searchToken = token; searching = true; highlighted = nil
    searchTask = Task {
      defer { if searchToken == token { searching = false; searchTask = nil; searchToken = nil; highlighted = options.first?.id } }
      do {
        try await Task.sleep(for: debounce)
        let users = try await service.reviewerCandidates(request: request, expected: snapshot, query: trimmed, at: root)
        guard !Task.isCancelled, valid(), showingPicker, searchToken == token else { return }
        candidates = users
      } catch {
        guard !Task.isCancelled, valid(), showingPicker, searchToken == token else { return }
        searchError = error.localizedDescription
      }
    }
  }

  func toggle(_ reviewer: GitHubPRReviewer) {
    guard !busy, !reviewer.requested, snapshot?.reviewers.contains(where: { $0.id == reviewer.id }) != true,
      reviewer.kind == .user else { return }
    if let index = selected.firstIndex(where: { "user:" + $0.id == reviewer.id }) { selected.remove(at: index) }
    else { selected.append(.init(login: reviewer.label, avatarURL: reviewer.avatarURL)) }
  }
  func move(_ amount: Int) {
    guard !options.isEmpty else { return }
    let index = options.firstIndex(where: { $0.id == highlighted }) ?? (amount > 0 ? -1 : options.count)
    highlighted = options[min(max(index + amount, 0), options.count - 1)].id
  }
  func closePicker() {
    showingPicker = false; query = ""; selected = []; candidates = []; searching = false
    searchError = nil; searchToken = nil; searchTask?.cancel(); searchTask = nil; highlighted = nil
  }

  @discardableResult func apply(_ action: GitHubPRReviewerAction, request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool, writable: @escaping @MainActor () -> Bool,
    changed: @escaping @MainActor () -> Void) -> Bool {
    guard valid(), canManage(request, writable: writable()), let expected = snapshot else { return false }
    let token = UUID()
    guard coordinator.begin(request.url, token: token) else { return false }
    loadToken = nil; loading = false; mutationToken = token; busy = true; error = nil
    operation = Task {
      defer {
        coordinator.end(request.url, token: token)
        if mutationToken == token { busy = false; mutationToken = nil; operation = nil }
      }
      do {
        let result = try await service.updateReviewers(action, request: request, expected: expected, at: root) {
          guard valid(), writable(), self.mutationToken == token else { throw CancellationError() }
        }
        guard !Task.isCancelled, valid(), mutationToken == token else { return }
        snapshot = result; requiresRefresh = false; changed()
      } catch {
        guard !Task.isCancelled, valid(), mutationToken == token else { return }
        self.error = error.localizedDescription
        if let failure = error as? GitHubPRReviewerFailure {
          if let current = failure.snapshot { snapshot = current }
          requiresRefresh = failure.requiresRefresh
        }
        if snapshot?.canManage == false { closePicker() }
      }
    }
    return true
  }
  func cancel() {
    loadToken = nil; loading = false; closePicker(); mutationToken = nil
    operation?.cancel(); operation = nil; busy = false
  }
}
