import Foundation

enum GitHubPRCommentKind: String, Codable, Sendable { case issue, review, code }

struct GitHubPRComment: Codable, Identifiable, Equatable, Sendable {
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
  var submittedAt: String? = nil
  var originalCommit: String? = nil
  var activityDate: String { kind == .review ? submittedAt ?? createdAt : createdAt }
  var displayBody: String { JavaScriptText.trimmed(body) }
  var quotedBody: String { displayBody.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n" }
}

struct GitHubPRReviewThread: Codable, Identifiable, Equatable, Sendable {
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
  var diffSide: String? = nil
  var startLine: Int? = nil
  var startDiffSide: String? = nil
  var originalStartLine: Int? = nil
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
  var isActivityPartial = false
  var createdAt: String? = nil
  var mergedAt: String? = nil
  var mergedBy: String? = nil
  var canReview: Bool { state == "OPEN" && viewer.lowercased() != author.lowercased() }
  var allComments: [GitHubPRComment] { comments + threads.flatMap(\.comments) }
  var commentIDs: Set<String> { Set(allComments.map(\.id)) }
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
  func accepts(_ body: String) -> Bool { self == .approve || !JavaScriptText.trimmed(body).isEmpty }
}

enum GitHubPRDiscussionAction: Equatable, Sendable {
  case post(body: String, thread: String?)
  case inline(body: String, anchor: GitHubPRInlineAnchor)
  case edit(id: String, kind: GitHubPRCommentKind, body: String)
  case delete(id: String, kind: GitHubPRCommentKind)
  case resolve(thread: String, resolved: Bool)
  case review(body: String, decision: GitHubPRReviewDecision, head: String)
  var creates: Bool {
    switch self { case .post, .inline, .review: true; default: false }
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
  var staleInline: GitHubPRInlineAnchor? = nil
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
