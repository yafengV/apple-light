import Foundation

struct GitHubPRCodePoint: Equatable, Sendable {
  let side: GitHubPRCommentPosition.Side
  let line: Int
  var row: Int = 0
  static func position(path: String, from first: Self, to last: Self) -> GitHubPRCommentPosition {
    let cross = first.side != last.side
    let start = cross ? first.line : min(first.line, last.line)
    let end = cross ? last.line : max(first.line, last.line)
    return .init(path: path, line: end, side: last.side,
      startLine: start != end || cross ? start : nil, startSide: cross ? first.side : nil)
  }
}

/// A draft remains bound to the code that was selected, including a changed base.
struct GitHubPRInlineAnchor: Equatable, Sendable {
  let position: GitHubPRCommentPosition
  let identity: GitHubPRCodeIdentity
  let fingerprint: String
  init(position: GitHubPRCommentPosition, snapshot: GitHubPRCodeSnapshot) throws {
    guard position.isValid, !position.path.contains("\u{0}"),
      let file = snapshot.files.first(where: { $0.path == position.path }), !file.binary,
      Self.valid(position, in: file) else { throw AgentFailure(message: "请选择当前文件差异中的有效代码行。") }
    self.position = position; identity = snapshot.identity; fingerprint = file.diff.fingerprint
  }
  func matches(_ snapshot: GitHubPRCodeSnapshot?) -> Bool {
    guard let snapshot, snapshot.identity == identity,
      let file = snapshot.files.first(where: { $0.path == position.path }) else { return false }
    return !file.binary && file.diff.fingerprint == fingerprint && Self.valid(position, in: file)
  }
  private static func valid(_ position: GitHubPRCommentPosition, in file: GitHubPRCodeFile) -> Bool {
    let start = position.startLine ?? position.line, side = position.startSide ?? position.side
    guard position.startSide == nil || position.startLine != nil,
      side != position.side || start <= position.line else { return false }
    var hasFirst = false, hasLast = false
    for line in file.diff.lines {
      if (side == .left ? line.oldLine : line.newLine) == start { hasFirst = true }
      if (position.side == .left ? line.oldLine : line.newLine) == position.line { hasLast = true }
    }
    return hasFirst && hasLast
  }
}

struct GitHubPRCodeChanged: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
