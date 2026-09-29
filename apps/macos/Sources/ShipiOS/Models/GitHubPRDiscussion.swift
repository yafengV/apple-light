import Foundation

enum GitHubPRCommentKind: String, Sendable { case issue, review, code }

struct GitHubPRComment: Identifiable, Equatable, Sendable {
  let id: String
  let kind: GitHubPRCommentKind
  let body: String
  let author: String
  let authorType: String
  let createdAt: String
  let url: String?
  let canUpdate: Bool
  let canDelete: Bool
  var reviewState: String? = nil
  var commit: String? = nil
  var avatarURL: String? = nil
  var quotedBody: String { body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
}

struct GitHubPRReviewThread: Identifiable, Equatable, Sendable {
  let id: String
  let path: String
  let line: Int?
  let originalLine: Int?
  let diffHunk: String
  let isResolved: Bool
  let isOutdated: Bool
  let canReply: Bool
  let canResolve: Bool
  let canUnresolve: Bool
  var comments: [GitHubPRComment]
}

struct GitHubPRActivityEvent: Identifiable, Equatable, Sendable {
  let id: String
  let kind: String
  let author: String
  let createdAt: String
  let text: String
  let url: String?
}

enum GitHubPRActivityItem: Identifiable, Equatable, Sendable {
  case comment(GitHubPRComment), thread(GitHubPRReviewThread), event(GitHubPRActivityEvent)
  var id: String {
    switch self { case .comment(let x): "comment:" + x.id
    case .thread(let x): "thread:" + x.id
    case .event(let x): "event:" + x.id }
  }
  var createdAt: String {
    switch self { case .comment(let x): x.createdAt
    case .thread(let x): x.comments.first?.createdAt ?? ""
    case .event(let x): x.createdAt }
  }
}

struct GitHubPRDiscussionSnapshot: Equatable, Sendable {
  let requestURL: String
  let nodeID: String
  let viewer: String
  let author: String
  let state: String
  let head: String
  var comments: [GitHubPRComment]
  var threads: [GitHubPRReviewThread]
  var events: [GitHubPRActivityEvent]
  var omittedTypes: Set<String>
  var canReview: Bool { state == "OPEN" && viewer.lowercased() != author.lowercased() }
  var allComments: [GitHubPRComment] { comments + threads.flatMap(\.comments) }
  var commentIDs: Set<String> { Set(allComments.map(\.id)) }
  var activity: [GitHubPRActivityItem] {
    (comments.map(GitHubPRActivityItem.comment) + threads.map(GitHubPRActivityItem.thread)
      + events.map(GitHubPRActivityItem.event)).sorted {
        $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
      }
  }
  func comment(_ id: String) -> GitHubPRComment? { allComments.first { $0.id == id } }
}

enum GitHubPRReviewDecision: String, CaseIterable, Identifiable, Sendable {
  case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
  var id: String { rawValue }
  var label: String {
    switch self { case .comment: "评论"; case .approve: "批准"; case .requestChanges: "要求修改" }
  }
  var resultState: String {
    switch self { case .comment: "COMMENTED"; case .approve: "APPROVED"; case .requestChanges: "CHANGES_REQUESTED" }
  }
  func accepts(_ body: String) -> Bool { self == .approve || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum GitHubPRDiscussionAction: Equatable, Sendable {
  case post(body: String, thread: String?)
  case edit(id: String, kind: GitHubPRCommentKind, body: String)
  case delete(id: String, kind: GitHubPRCommentKind)
  case resolve(thread: String, resolved: Bool)
  case review(body: String, decision: GitHubPRReviewDecision, head: String)
  var creates: Bool {
    switch self { case .post, .review: true; default: false }
  }
}

struct GitHubPRDiscussionAttempt: Equatable, Sendable {
  let action: GitHubPRDiscussionAction
  let baseline: GitHubPRDiscussionSnapshot
}

struct GitHubPRDiscussionFailure: LocalizedError {
  let message: String
  var snapshot: GitHubPRDiscussionSnapshot? = nil
  var uncertain: GitHubPRDiscussionAttempt? = nil
  var errorDescription: String? { message }
}

struct GitHubPRDiscussionRejected: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct GitHubPRDiscussionResult: Sendable {
  let snapshot: GitHubPRDiscussionSnapshot
  var notice: String? = nil
}

enum GitHubPRDiscussionErrorOwner: Hashable {
  case activity, general, draft(String), review, delete(String), thread(String)
}
