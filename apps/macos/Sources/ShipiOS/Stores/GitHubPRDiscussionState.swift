import Foundation
import Observation

@MainActor @Observable final class GitHubPRDiscussionUpdates {
  static let shared = GitHubPRDiscussionUpdates()
  private var versions: [String: UUID] = [:]
  func revision(dataRoot: URL, request: GitHubPullRequest) -> UUID? { versions[key(dataRoot, request)] }
  func publish(dataRoot: URL, request: GitHubPullRequest) { versions[key(dataRoot, request)] = UUID() }
  private func key(_ root: URL, _ request: GitHubPullRequest) -> String { root.standardizedFileURL.path + "\n" + request.url.lowercased() }
}

struct GitHubPRCommentDraft: Equatable {
  enum Target: Equatable {
    case edit(GitHubPRComment), reply(commentID: String, threadID: String?)
    case inline(id: String, anchor: GitHubPRInlineAnchor)
  }
  let target: Target
  var text: String
  var focus = UUID()
  var commentID: String {
    switch target { case .edit(let comment): comment.id; case .reply(let id, _), .inline(let id, _): id }
  }
}

/// Drafts are view-local; the same PR shares mutation ownership and change notifications.
@MainActor @Observable final class GitHubPRDiscussionState {
  private(set) var snapshot: GitHubPRDiscussionSnapshot?
  private(set) var loading = false
  private(set) var refreshing = false
  private(set) var staleInline: GitHubPRInlineAnchor?
  private(set) var readError: String?
  private(set) var busy = false
  private(set) var errors: [GitHubPRDiscussionErrorOwner: String] = [:]
  private(set) var pendingOwner: GitHubPRDiscussionErrorOwner?
  private var lastErrorOwner = GitHubPRDiscussionErrorOwner.activity
  var error: String? { errors[lastErrorOwner] ?? readError }
  private(set) var notice: String?
  private(set) var uncertain: GitHubPRDiscussionAttempt?
  var commentBody = ""
  var drafts: [String: GitHubPRCommentDraft] = [:]
  var deleteTarget: GitHubPRComment?
  var showingReview = false
  var reviewBody = ""
  var reviewDecision = GitHubPRReviewDecision.comment
  private(set) var reviewHead: String?
  var reviewFocus: UUID?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var readToken = UUID()
  @ObservationIgnored private(set) var operation: Task<Void, Never>?
  @ObservationIgnored private var pendingDraftID: String?
  @ObservationIgnored private let service: GitHubPRService
  private let coordinator: GitHubPRActionCoordinator

  init(service: GitHubPRService = .init(), coordinator: GitHubPRActionCoordinator? = nil) {
    self.service = service; self.coordinator = coordinator ?? .shared
  }
  func canWrite(_ request: GitHubPullRequest, writable: Bool) -> Bool {
    writable && snapshot != nil && readError == nil && !loading && !busy && uncertain == nil && !coordinator.isBusy(request.url)
  }
  func codeReloaded(_ snapshot: GitHubPRCodeSnapshot) {
    guard snapshot.identity.nodeID == self.snapshot?.nodeID else { return }
    staleInline = nil
  }
  func isCodeStale(_ identity: GitHubPRCodeIdentity) -> Bool { staleInline?.identity == identity }
  func message(for owner: GitHubPRDiscussionErrorOwner) -> String? { errors[owner] }
  var uncertainOwner: GitHubPRDiscussionErrorOwner? { uncertain.map { errorOwner($0.action) } }
  func canEdit(_ owner: GitHubPRDiscussionErrorOwner, writable: Bool) -> Bool {
    writable && snapshot != nil && readError == nil && !loading && pendingOwner != owner && uncertainOwner != owner
  }
  func clearError(_ owner: GitHubPRDiscussionErrorOwner = .activity) {
    guard pendingOwner != owner, uncertainOwner != owner else { return }; errors[owner] = nil
  }
  private func errorOwner(_ action: GitHubPRDiscussionAction) -> GitHubPRDiscussionErrorOwner {
    switch action {
    case .inline: pendingDraftID.map(GitHubPRDiscussionErrorOwner.draft) ?? .activity
    case .post: pendingDraftID.map(GitHubPRDiscussionErrorOwner.draft) ?? .general
    case .edit(let id, _, _): .draft(id)
    case .review: .review
    case .delete(let id, _): .delete(id)
    case .resolve(let id, _): .thread(id)
    }
  }
  func beginEdit(_ comment: GitHubPRComment) {
    guard pendingOwner != .draft(comment.id), uncertainOwner != .draft(comment.id), comment.canUpdate else { return }
    drafts[comment.id] = .init(target: .edit(comment), text: comment.body); errors[.draft(comment.id)] = nil
  }
  func beginReply(_ comment: GitHubPRComment, thread: GitHubPRReviewThread?, quote: Bool) {
    guard pendingOwner != .draft(comment.id), uncertainOwner != .draft(comment.id), thread == nil || thread?.canReply == true else { return }
    drafts[comment.id] = .init(target: .reply(commentID: comment.id, threadID: thread?.id), text: quote ? comment.quotedBody : "")
    errors[.draft(comment.id)] = nil
  }
  @discardableResult func beginInline(_ anchor: GitHubPRInlineAnchor) -> String? {
    guard !busy, uncertain == nil, readError == nil, !isCodeStale(anchor.identity), let snapshot,
      snapshot.nodeID == anchor.identity.nodeID, snapshot.head.lowercased() == anchor.identity.head.lowercased() else { return nil }
    let point = anchor.position
    if let existing = inlineDrafts.first(where: { _, draft in
      guard case .inline(_, let other) = draft.target else { return false }
      return other.position.path == point.path && other.position.side == point.side && other.position.line == point.line
    }) {
      drafts[existing.id]?.focus = UUID(); return existing.id
    }
    guard !snapshot.threads.contains(where: { thread in
      guard let position = thread.position else { return false }
      return position.path == point.path && position.side == point.side && position.line == point.line
    }) else { return nil }
    let id = UUID().uuidString
    drafts[id] = .init(target: .inline(id: id, anchor: anchor), text: "")
    return id
  }
  var inlineDrafts: [(id: String, draft: GitHubPRCommentDraft)] {
    drafts.compactMap { id, draft in
      if case .inline = draft.target { return (id, draft) }; return nil
    }.sorted { $0.id < $1.id }
  }
  func cancelDraft(_ id: String) { guard pendingOwner != .draft(id), uncertainOwner != .draft(id) else { return }; drafts[id] = nil; errors[.draft(id)] = nil }
  func openReview() {
    guard !busy, uncertain == nil, snapshot?.canReview == true else { return }
    reviewHead = snapshot?.head; reviewFocus = UUID(); showingReview = true; errors[.review] = nil
  }
  func closeReview() { guard pendingOwner != .review else { return }; showingReview = false; if uncertainOwner != .review { errors[.review] = nil } }
  @discardableResult func validateReviewSubmission() -> Bool {
    guard showingReview, pendingOwner != .review, uncertainOwner != .review else { return false }
    if !reviewDecision.accepts(reviewBody) {
      errors[.review] = reviewDecision == .requestChanges ? "要求修改前请添加评论。" : "提交审查前请添加评论。"
      lastErrorOwner = .review; return false
    }
    errors[.review] = nil; return true
  }
  func draftAction(_ id: String) -> GitHubPRDiscussionAction? {
    guard let draft = drafts[id] else { return nil }
    switch draft.target {
    case .edit(let comment): return .edit(id: comment.id, kind: comment.kind, body: draft.text)
    case .reply(_, let thread): return .post(body: draft.text, thread: thread)
    case .inline(_, let anchor): return .inline(body: draft.text, anchor: anchor)
    }
  }
  var reviewAction: GitHubPRDiscussionAction? {
    reviewHead.map { .review(body: reviewBody, decision: reviewDecision, head: $0) }
  }

  func load(_ request: GitHubPullRequest, at root: URL, valid: @escaping @MainActor () -> Bool) async {
    guard valid(), !busy else { return }
    let token = UUID(), owner = generation
    readToken = token; loading = snapshot == nil; refreshing = true; readError = nil
    errors[.activity] = nil
    defer { if readToken == token, generation == owner { loading = false; refreshing = false } }
    do {
      let result = try await service.discussion(for: request, at: root)
      guard !Task.isCancelled, readToken == token, generation == owner, valid() else { return }
      snapshot = result
    } catch {
      guard !Task.isCancelled, readToken == token, generation == owner, valid() else { return }
      errors[.activity] = error.localizedDescription; lastErrorOwner = .activity
      readError = error.localizedDescription
    }
  }

  @discardableResult func start(_ action: GitHubPRDiscussionAction, request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool, writable: @escaping @MainActor () -> Bool,
    draftID: String? = nil, changed: @escaping @MainActor () -> Void = {}) -> Bool {
    guard valid(), canWrite(request, writable: writable()), let snapshot else { return false }
    if case .inline(_, let anchor) = action, isCodeStale(anchor.identity) { return false }
    pendingDraftID = draftID
    return perform(action: action, request: request, valid: valid, changed: changed) {
      try await self.service.applyDiscussion(action, expected: snapshot, request: request, at: root) {
        guard valid(), writable() else { throw CancellationError() }
      }
    }
  }

  @discardableResult func confirm(request: GitHubPullRequest, at root: URL,
    valid: @escaping @MainActor () -> Bool, changed: @escaping @MainActor () -> Void = {}) -> Bool {
    guard valid(), !busy, let uncertain else { return false }
    return perform(action: uncertain.action, request: request, valid: valid, changed: changed) {
      try await self.service.confirmDiscussion(uncertain, request: request, at: root)
    }
  }

  private func perform(action: GitHubPRDiscussionAction, request: GitHubPullRequest, valid: @escaping @MainActor () -> Bool,
    changed: @escaping @MainActor () -> Void,
    work: @escaping @MainActor () async throws -> GitHubPRDiscussionResult) -> Bool {
    let token = UUID(), owner = generation, errorOwner = self.errorOwner(action)
    guard coordinator.begin(request.url, token: token) else { return false }
    readToken = UUID(); loading = false; refreshing = false; busy = true; pendingOwner = errorOwner; errors[errorOwner] = nil; notice = nil
    operation = Task {
      defer {
        coordinator.end(request.url, token: token)
        if generation == owner { busy = false; pendingOwner = nil; operation = nil }
      }
      do {
        let result = try await work()
        guard !Task.isCancelled, generation == owner, valid() else { return }
        snapshot = result.snapshot; notice = result.notice; uncertain = nil
        switch action {
        case .review: showingReview = false; reviewBody = ""; reviewDecision = .comment
        case .delete: deleteTarget = nil
        case .edit(let id, _, _): drafts[id] = nil
        case .post, .inline:
          if let pendingDraftID { drafts[pendingDraftID] = nil } else { commentBody = "" }
        case .resolve: break
        }
        pendingDraftID = nil
        changed()
      } catch {
        guard !Task.isCancelled, generation == owner, valid() else { return }
        if let failure = error as? GitHubPRDiscussionFailure {
          if let snapshot = failure.snapshot { self.snapshot = snapshot }
          uncertain = failure.uncertain
          if let stale = failure.staleInline { staleInline = stale }
        }
        errors[errorOwner] = error.localizedDescription; lastErrorOwner = errorOwner
      }
    }
    return true
  }

  func cancel() {
    generation = UUID(); readToken = UUID(); operation?.cancel(); operation = nil; loading = false; refreshing = false; busy = false; pendingOwner = nil
  }
}
