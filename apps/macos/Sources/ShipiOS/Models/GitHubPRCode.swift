import Foundation

struct GitHubPRCodeRequest: Equatable, Sendable {
  let taskID: String
  let root: URL
  let pullRequest: GitHubPullRequest
  let head: String
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.taskID == rhs.taskID && lhs.root == rhs.root && lhs.head.lowercased() == rhs.head.lowercased()
      && lhs.pullRequest.number == rhs.pullRequest.number && lhs.pullRequest.validatedURL == rhs.pullRequest.validatedURL
      && lhs.pullRequest.headRefName == rhs.pullRequest.headRefName && lhs.pullRequest.baseRefName == rhs.pullRequest.baseRefName
  }
}

struct GitHubPRCodeIdentity: Equatable, Sendable {
  let nodeID: String
  let head: String
  let base: String
  let headBranch: String
  let baseBranch: String
  let changedFiles: Int
}

struct GitHubPRCodeSnapshot: Equatable, Sendable {
  let identity: GitHubPRCodeIdentity
  let files: [GitHubPRCodeFile]
}

struct GitHubPRCodeFile: Identifiable, Equatable, Sendable {
  enum Kind: String, Sendable { case modified, added, deleted, renamed, copied }
  var id: String { path }
  let path: String
  let oldPath: String?
  let patch: String
  let kind: Kind
  let binary: Bool
  let diff: ReviewDiff
  var defaultCollapsed: Bool { kind == .deleted }
  init(path: String, oldPath: String?, patch: String, kind: Kind, binary: Bool) {
    self.path = path; self.oldPath = oldPath; self.patch = patch; self.kind = kind; self.binary = binary
    diff = ReviewDiff(patch)
  }
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.path == rhs.path && lhs.oldPath == rhs.oldPath && lhs.patch == rhs.patch && lhs.kind == rhs.kind && lhs.binary == rhs.binary
  }
  func matches(_ position: GitHubPRCommentPosition) -> Bool {
    path == position.path || position.side == .left && oldPath == position.path
  }
  func lineID(_ line: ReviewDiffLine) -> String { path + "\u{1f}" + String(line.id) }

  static func parse(_ source: String) throws -> [Self] {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    let slices = CodexTurnDiffFiles.parse(source)
    var seen = Set<String>()
    return try slices.map { slice in
      let lines = slice.patch.components(separatedBy: "\n")
      guard let header = lines.first(where: { $0.hasPrefix("diff --git ") }) else {
        throw AgentFailure(message: "GitHub 未返回有效的文件差异。")
      }
      let paths = CodexTurnDiffFiles.headerPaths(header)
      var old = paths.old
      var new = paths.new
      var kind = Kind.modified
      for line in lines.dropFirst() {
        if line.hasPrefix("@@ ") || line.hasPrefix("Binary files ") || line == "GIT binary patch" { break }
        if line.hasPrefix("--- ") { old = CodexTurnDiffFiles.markerPath(String(line.dropFirst(4))) }
        if line.hasPrefix("+++ ") { new = CodexTurnDiffFiles.markerPath(String(line.dropFirst(4))) }
        if line.hasPrefix("new file mode ") { kind = .added }
        if line.hasPrefix("deleted file mode ") { kind = .deleted }
        if line.hasPrefix("rename from ") { kind = .renamed; old = CodexTurnDiffFiles.decodeGitPath(String(line.dropFirst(12))) }
        if line.hasPrefix("rename to ") { new = CodexTurnDiffFiles.decodeGitPath(String(line.dropFirst(10))) }
        if line.hasPrefix("copy from ") { kind = .copied; old = CodexTurnDiffFiles.decodeGitPath(String(line.dropFirst(10))) }
        if line.hasPrefix("copy to ") { new = CodexTurnDiffFiles.decodeGitPath(String(line.dropFirst(8))) }
      }
      guard let path = kind == .deleted ? old : new, validPath(path), seen.insert(path).inserted,
        old == nil || validPath(old!) else { throw AgentFailure(message: "文件差异包含无效或重复路径。") }
      return .init(path: path, oldPath: old, patch: slice.patch, kind: kind,
        binary: lines.contains { $0.hasPrefix("Binary files ") || $0 == "GIT binary patch" })
    }
  }

  private static func validPath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\u{0}")
      && !path.split(separator: "/").contains("..")
  }
}

/// Pair adjacent deletion/addition runs by their visual row; context keeps both sides.
struct GitHubPRSplitLine: Identifiable, Sendable {
  let id: Int
  let left: ReviewDiffLine?
  let right: ReviewDiffLine?
  static func rows(_ lines: [ReviewDiffLine]) -> [Self] {
    var result: [Self] = [], index = 0
    while index < lines.count {
      let line = lines[index]
      if line.kind == .deletion || line.kind == .addition {
        var deletions: [ReviewDiffLine] = [], additions: [ReviewDiffLine] = []
        while index < lines.count, lines[index].kind == .deletion {
          deletions.append(lines[index]); index += 1
        }
        while index < lines.count, lines[index].kind == .addition {
          additions.append(lines[index]); index += 1
        }
        for offset in 0..<max(deletions.count, additions.count) {
          result.append(.init(id: result.count, left: offset < deletions.count ? deletions[offset] : nil,
            right: offset < additions.count ? additions[offset] : nil))
        }
      } else {
        result.append(.init(id: result.count, left: line, right: line)); index += 1
      }
    }
    return result
  }
}
