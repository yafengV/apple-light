import Foundation

enum GitHunkAction: String {
  case stage, unstage, revert
  var scope: GitReviewScope { self == .unstage ? .staged : .unstaged }
  var title: String {
    switch self {
    case .stage: "暂存此块"
    case .unstage: "取消暂存此块"
    case .revert: "撤销此块"
    }
  }
  var arguments: [String] {
    switch self {
    case .stage: ["--cached"]
    case .unstage: ["--cached", "--reverse"]
    case .revert: ["--reverse"]
    }
  }
}

struct ReviewHunk: Identifiable, Equatable, Sendable {
  let id: Int
  let title: String
  let text: String
}

extension ReviewDiff {
  var hunks: [ReviewHunk] {
    let starts = lines.indices.filter { lines[$0].kind == .header }
    return starts.enumerated().map { position, start in
      let end = position + 1 < starts.count ? starts[position + 1] : lines.endIndex
      return ReviewHunk(
        id: lines[start].id, title: lines[start].text,
        text: lines[start..<end].map(\.text).joined(separator: "\n") + "\n")
    }
  }
  var supportsHunkActions: Bool {
    guard lines.filter({ $0.text.hasPrefix("diff --git ") }).count == 1,
      let first = lines.firstIndex(where: { $0.kind == .header })
    else { return false }
    let header = lines[..<first].map(\.text)
    return !header.contains { line in
      let hasMode =
        line.hasPrefix("index ") || line.hasPrefix("old mode ") || line.hasPrefix("new mode ")
        || line.hasPrefix("new file mode ") || line.hasPrefix("deleted file mode ")
      return (hasMode && (line.hasSuffix("120000") || line.hasSuffix("160000")))
        || line.hasPrefix("Binary files ")
    }
  }

  func patch(for hunkID: Int, path: String) throws -> String {
    guard supportsHunkActions, let hunk = hunks.first(where: { $0.id == hunkID }),
      let first = lines.firstIndex(where: { $0.kind == .header })
    else {
      throw AgentFailure(message: "此差异不能按块操作，请刷新或使用文件级操作。")
    }
    let header = lines[..<first].map(\.text)
    if header.contains(where: {
      $0.hasPrefix("new file mode ") || $0.hasPrefix("deleted file mode ")
    }) {
      return header.joined(separator: "\n") + "\n" + hunk.text
    }
    // Content-only changes, including staged renames, target the current path.
    // Omit rename/mode metadata so accepting one hunk cannot also change either.
    let old = Self.quotedGitPath("a/" + path)
    let new = Self.quotedGitPath("b/" + path)
    return "diff --git \(old) \(new)\n--- \(old)\n+++ \(new)\n" + hunk.text
  }

  private static func quotedGitPath(_ path: String) -> String {
    "\""
      + path.utf8.map { byte in
        switch byte {
        case 34: "\\\""
        case 92: "\\\\"
        case 32...126: String(UnicodeScalar(byte))
        default: String(format: "\\%03o", byte)
        }
      }.joined() + "\""
  }
}
