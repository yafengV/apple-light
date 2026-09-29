import Foundation

struct GitHubPRCommentCard: Identifiable, Equatable, Sendable {
  let comment: GitHubPRComment
  let thread: GitHubPRReviewThread?
  var id: String { comment.id }
  var replies: [GitHubPRComment] {
    (thread?.comments.dropFirst() ?? []).filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
  var defaultCollapsed: Bool { thread?.isResolved == true || comment.authorType != "User" }
  var allIDs: Set<String> { Set((thread?.comments ?? [comment]).map(\.id)) }
}

extension GitHubPRDiscussionSnapshot {
  var commentCards: [GitHubPRCommentCard] {
    activity.compactMap { item in
      switch item {
      case .comment(let comment): return .init(comment: comment, thread: nil)
      case .thread(let thread): return thread.comments.first.map { .init(comment: $0, thread: thread) }
      default: return nil
      }
    }
  }
}
