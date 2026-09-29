import Foundation

struct PullRequestCommentAttachment: Codable, Equatable, Identifiable, Sendable {
  let thread: GitHubPRReviewThread
  var guidance = ""
  var id: String { thread.id }
  var position: GitHubPRCommentPosition? { thread.position }
  var body: String {
    thread.comments.compactMap { comment -> String? in
      let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      let author = comment.author.trimmingCharacters(in: .whitespacesAndNewlines)
      return author.isEmpty || author == "未知作者" ? body : "@\(author):\n\(body)"
    }.joined(separator: "\n\n")
  }
  var isValid: Bool {
    !id.isEmpty && !thread.isResolved && position?.isValid == true && !body.isEmpty
      && !thread.comments.isEmpty && thread.comments.allSatisfy { $0.kind == .code && !$0.id.isEmpty }
  }
}

extension PullRequestCommentAttachment {
  enum CodingKeys: String, CodingKey { case thread, guidance, position }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(thread: try c.decode(GitHubPRReviewThread.self, forKey: .thread),
      guidance: try c.decodeIfPresent(String.self, forKey: .guidance) ?? "")
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(thread, forKey: .thread); try c.encode(guidance, forKey: .guidance)
    try c.encodeIfPresent(position, forKey: .position)
  }
}
