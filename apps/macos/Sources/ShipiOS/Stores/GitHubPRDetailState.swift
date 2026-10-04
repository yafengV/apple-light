import Foundation
import Observation

/// Mutation ownership is shared by all windows showing the same PR.
@MainActor @Observable final class GitHubPRActionCoordinator {
  static let shared = GitHubPRActionCoordinator()
  private var operations: [String: UUID] = [:]
  func isBusy(_ url: String) -> Bool { operations[url.lowercased()] != nil }
  func begin(_ url: String, token: UUID) -> Bool {
    guard !isBusy(url) else { return false }
    operations[url.lowercased()] = token
    return true
  }
  func end(_ url: String, token: UUID) {
    guard operations[url.lowercased()] == token else { return }
    operations[url.lowercased()] = nil
  }
}

@MainActor @Observable final class GitHubPRDetailState {
  private(set) var snapshot: GitHubPRMergeSnapshot?
  private(set) var loading = false
  private(set) var action: GitHubPRMergeAction?
  private(set) var statusAction: GitHubPRStatus?
  private(set) var statusRequiresRefresh = false
  private(set) var error: String?
  private(set) var notice: String?
  var showingMergeConfirmation = false
  var selectedMethod = GitHubPRMergeMethod.merge
  private(set) var fallbackToSquash = false
  @ObservationIgnored private let service: GitHubPRService
  private let coordinator: GitHubPRActionCoordinator
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var readToken = UUID()
  @ObservationIgnored private var observedEditorRevision: UUID?
  @ObservationIgnored private(set) var operation: Task<Void, Never>?

  init(service: GitHubPRService = GitHubPRService(), coordinator: GitHubPRActionCoordinator? = nil) {
    self.service = service; self.coordinator = coordinator ?? .shared
  }

  func busy(for request: GitHubPullRequest) -> Bool { coordinator.isBusy(request.url) }
  var metadataError: String? { snapshot == nil ? error : nil }
  func acceptMetadata(_ snapshot: GitHubPRMergeSnapshot) {
    guard action == nil, statusAction == nil else { return }
    readToken = UUID(); loading = false
    self.snapshot = snapshot
  }
  func trackEditor(_ editor: GitHubPREditState) { observedEditorRevision = editor.revision }
  func acceptEditorChanges(_ editor: GitHubPREditState) -> GitHubPRMergeSnapshot? {
    guard observedEditorRevision != editor.revision else { return nil }
    observedEditorRevision = editor.revision
    guard let snapshot = editor.snapshot else { return nil }
    acceptMetadata(snapshot)
    return snapshot
  }
  func mergeDisabledReason(for request: GitHubPullRequest, writable: Bool) -> String? {
    if busy(for: request) { return "另一个 PR 操作正在进行。" }
    if !writable { return "当前任务不能修改 PR。" }
    if statusRequiresRefresh { return "请刷新以确认上次状态操作的结果。" }
    if loading || snapshot == nil { return "请先读取最新 PR 状态。" }
    return snapshot?.mergeDisabledReason
  }
  func autoMergeDisabledReason(for request: GitHubPullRequest, writable: Bool) -> String? {
    if busy(for: request) { return "另一个 PR 操作正在进行。" }
    if !writable { return "当前任务不能修改 PR。" }
    if statusRequiresRefresh { return "请刷新以确认上次状态操作的结果。" }
    if loading || snapshot == nil { return "请先读取最新 PR 状态。" }
    return snapshot?.autoMergeDisabledReason
  }
  func statusDisabledReason(for request: GitHubPullRequest, writable: Bool) -> String? {
    if busy(for: request) { return "另一个 PR 操作正在进行。" }
    if !writable { return "当前任务不能修改 PR。" }
    if statusRequiresRefresh { return "请刷新以确认上次状态操作的结果。" }
    guard !loading, let snapshot else { return "请先读取最新 PR 状态。" }
    guard snapshot.isAuthor, let viewer = snapshot.viewer, !viewer.isEmpty,
      let node = snapshot.nodeID, !node.isEmpty else { return "仅 PR 作者可以更改状态。" }
    if GitHubPRStatus(snapshot.details) == .merged { return "此 PR 已合并。" }
    return nil
  }

  @discardableResult func startStatus(_ next: GitHubPRStatus, request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool,
    writable: @escaping @MainActor () -> Bool,
    updated: @escaping @MainActor (GitHubPullRequest) -> Void,
    changed: @escaping @MainActor () -> Void = {},
    reportError: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
    guard statusDisabledReason(for: request, writable: writable()) == nil, valid(), let expected = snapshot,
      next.canSelect(from: .init(expected.details)) else { return false }
    let token = UUID(), owner = generation
    guard coordinator.begin(request.url, token: token) else { return false }
    statusAction = next; error = nil; notice = nil; showingMergeConfirmation = false
    operation = Task {
      var publish = false
      defer {
        coordinator.end(request.url, token: token)
        if generation == owner {
          statusAction = nil; operation = nil
          if publish, valid() { changed() }
        }
      }
      do {
        let result = try await service.updateStatus(next, expected: expected, request: request, at: root) {
          guard valid(), writable(), self.generation == owner else { throw CancellationError() }
        }
        guard !Task.isCancelled, generation == owner, valid() else { return }
        snapshot = result; statusRequiresRefresh = false; publish = true
        updated(result.details.recorded(updating: request))
      } catch {
        guard !Task.isCancelled, generation == owner, valid() else { return }
        if let failure = error as? GitHubPRStatusFailure {
          snapshot = failure.snapshot; statusRequiresRefresh = failure.requiresRefresh
          if let snapshot { updated(snapshot.details.recorded(updating: request)) }
          publish = true
        }
        self.error = error.localizedDescription
        reportError(error.localizedDescription)
      }
    }
    return true
  }

  func selectMethod(_ method: GitHubPRMergeMethod) {
    guard action == nil, statusAction == nil, snapshot?.allowedMethods.contains(method) == true else { return }
    selectedMethod = method; fallbackToSquash = false
  }
  func openConfirmation(for request: GitHubPullRequest, writable: Bool) {
    guard mergeDisabledReason(for: request, writable: writable) == nil else { return }
    error = nil; notice = nil; showingMergeConfirmation = true
  }

  func refresh(_ request: GitHubPullRequest, at root: URL, preferred: GitHubPRMergeMethod,
    valid: @escaping @MainActor () -> Bool,
    updated: @escaping @MainActor (GitHubPullRequest) -> Void) async {
    guard !loading, action == nil, statusAction == nil, valid() else { return }
    let token = UUID(), owner = generation
    readToken = token; loading = true; snapshot = nil; error = nil; notice = nil
    defer { if readToken == token && generation == owner { loading = false } }
    do {
      let result = try await service.mergeSnapshot(for: request, at: root)
      guard !Task.isCancelled, generation == owner, readToken == token, valid() else { return }
      snapshot = result; statusRequiresRefresh = false
      selectedMethod = result.method(preferred: fallbackToSquash ? .squash : preferred)
      updated(result.details.recorded(updating: request))
    } catch {
      guard !Task.isCancelled, generation == owner, readToken == token, valid() else { return }
      self.error = error.localizedDescription
    }
  }

  @discardableResult func start(_ next: GitHubPRMergeAction, request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool,
    writable: @escaping @MainActor () -> Bool,
    updated: @escaping @MainActor (GitHubPullRequest) -> Void,
    saveFallback: @escaping @MainActor () -> Bool = { true }) -> Bool {
    let reason: String?
    switch next {
    case .merge: reason = mergeDisabledReason(for: request, writable: writable())
    case .autoMerge: reason = autoMergeDisabledReason(for: request, writable: writable())
    }
    guard reason == nil, valid(), let expected = snapshot else { return false }
    let token = UUID(), owner = generation, fallback = fallbackToSquash
    guard coordinator.begin(request.url, token: token) else { return false }
    action = next; error = nil; notice = nil
    operation = Task {
      defer {
        coordinator.end(request.url, token: token)
        if generation == owner { action = nil; operation = nil }
      }
      do {
        let result = try await service.apply(next, to: expected, request: request, at: root) {
          guard valid(), writable(), self.generation == owner else { throw CancellationError() }
        }
        guard !Task.isCancelled, generation == owner, valid() else { return }
        snapshot = result.snapshot; notice = result.notice
        updated(result.snapshot.details.recorded(updating: request))
        if fallback, next.usesMergeMethod, next.method == .squash, next.isConfirmed(by: result.snapshot) {
          if !saveFallback() { notice = "PR 操作已完成，但无法保存默认压缩合并方式。" }
          fallbackToSquash = false
        }
        if case .merge = next { showingMergeConfirmation = false }
      } catch {
        guard !Task.isCancelled, generation == owner, valid() else { return }
        if let failure = error as? GitHubPRMergeFailure {
          snapshot = failure.snapshot
          if let snapshot { updated(snapshot.details.recorded(updating: request)) }
        }
        self.error = error.localizedDescription
        if next.usesMergeMethod, next.method == .merge,
          error.localizedDescription.range(of: "merge commits are not allowed on this repository", options: .caseInsensitive) != nil {
          selectedMethod = .squash; fallbackToSquash = true
          self.error = "此仓库已禁用合并提交，请使用压缩合并重试。"
        } else if let snapshot {
          selectedMethod = snapshot.method(preferred: selectedMethod)
        }
      }
    }
    return true
  }

  func cancel() {
    generation = UUID(); readToken = UUID()
    operation?.cancel(); operation = nil; loading = false; action = nil
    statusAction = nil; statusRequiresRefresh = false
    snapshot = nil; error = nil; notice = nil; showingMergeConfirmation = false
    fallbackToSquash = false; selectedMethod = .merge
  }
}
