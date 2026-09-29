import Foundation

struct PullRequestCommentAttachment: Codable, Equatable, Identifiable, Sendable {
  let thread: GitHubPRReviewThread
  var guidance = ""
  var id: String { thread.id }
  var body: String { thread.comments.map { "@\($0.author):\n\($0.body)" }.joined(separator: "\n\n") }
  var isValid: Bool {
    !id.isEmpty && !thread.isResolved && thread.line.map { $0 > 0 } == true
      && ["LEFT", "RIGHT"].contains(thread.diffSide ?? "") && !thread.path.isEmpty
      && !thread.path.hasPrefix("/") && !thread.path.split(separator: "/").contains("..")
      && !thread.comments.isEmpty && thread.comments.allSatisfy { $0.kind == .code && !$0.id.isEmpty }
  }
}
