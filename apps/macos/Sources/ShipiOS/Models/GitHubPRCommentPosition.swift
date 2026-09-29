import Foundation

struct GitHubPRCommentPosition: Codable, Equatable, Sendable {
  enum Side: String, Codable, Sendable {
    case left, right
    var prefix: String { self == .left ? "L" : "R" }
    init?(apiValue: String?) {
      switch apiValue { case "LEFT": self = .left; case "RIGHT": self = .right; default: return nil }
    }
  }
  let path: String
  let line: Int
  let side: Side
  let startLine: Int?
  let startSide: Side?
  var label: String {
    let start = startLine ?? line, firstSide = startSide ?? side
    return start == line && firstSide == side ? "Line \(side.prefix)\(line)"
      : "\(firstSide.prefix)\(start)–\(side.prefix)\(line)"
  }
  var isValid: Bool {
    line > 0 && (startLine == nil || startLine! > 0) && !path.isEmpty
      && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
  }
  enum CodingKeys: String, CodingKey { case path, line, side, startLine = "start_line", startSide = "start_side" }
}

extension GitHubPRReviewThread {
  /// Preserve GitHub's current and original fields; normalize only when presenting a location.
  var position: GitHubPRCommentPosition? {
    guard let end = line ?? originalLine ?? startLine ?? originalStartLine,
      let side = GitHubPRCommentPosition.Side(apiValue: diffSide) else { return nil }
    let first = line == nil && originalLine != nil
      ? originalStartLine ?? startLine ?? end : startLine ?? originalStartLine ?? end
    let firstSide = GitHubPRCommentPosition.Side(apiValue: startDiffSide) ?? side
    return .init(path: path.trimmingCharacters(in: .whitespacesAndNewlines), line: end, side: side,
      startLine: first == end ? nil : first, startSide: firstSide == side ? nil : firstSide)
  }
  /// The saved hunk uses original lines even when the current file has moved.
  var hunkPosition: GitHubPRCommentPosition? {
    guard let current = position else { return nil }
    guard let originalLine else { return current }
    let start = originalStartLine ?? originalLine
    return .init(path: current.path, line: originalLine, side: current.side,
      startLine: start == originalLine ? nil : start, startSide: current.startSide)
  }
}
