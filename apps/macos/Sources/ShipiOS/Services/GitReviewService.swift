import Foundation

enum GitReviewService {
  static let modelReviewMaximumBytes = 512 * 1024

  static func fileDiff(_ file: GitFile, scope: GitReviewScope, arguments: [String], at root: URL)
    async throws -> ReviewDiff
  {
    if file.untracked && scope == .unstaged {
      let content = try await Task.detached {
        try LocalWorkspaceService.read(file.path, root: root)
      }.value
      return ReviewDiff.untracked(content)
    }
    return ReviewDiff(
      try await checked(arguments + ["--"] + file.comparisonPaths(scope: scope), at: root))
  }
  static func checked(_ args: [String], at root: URL) async throws -> String {
    let output = try await LocalWorkspaceService.git(args, at: root)
    guard output.status == 0 else { throw AgentFailure(message: output.text) }
    return output.text
  }

  static func commits(at root: URL) async throws -> [GitReviewChoice] {
    let head = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
    guard head.status == 0 else { return [] }
    let output = try await checked(["log", "-100", "--format=%H%x00%s", "HEAD", "--"], at: root)
    return output.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return GitReviewChoice(id: String(parts[0]), title: "\(parts[0].prefix(7)) · \(parts[1])")
    }
  }

  static func branches(at root: URL) async throws -> [GitReviewChoice] {
    let output = try await checked(
      [
        "for-each-ref", "--format=%(refname)%00%(refname:short)%00%(symref)", "refs/heads",
        "refs/remotes",
      ], at: root)
    return output.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[2].isEmpty else { return nil }
      return GitReviewChoice(id: String(parts[0]), title: String(parts[1]))
    }
  }

  /// Resolve refs to immutable IDs before comparing. Never interpret a ref as a CLI option.
  private static func commitID(_ ref: String, at root: URL) async throws -> String {
    try await checked(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], at: root)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func arguments(scope: GitReviewScope, selection: String, at root: URL) async throws
    -> [String]
  {
    let flags = [
      "--no-ext-diff", "--no-textconv", "--find-renames", "--src-prefix=a/", "--dst-prefix=b/",
      "--unified=3",
    ]
    switch scope {
    case .unstaged: return ["diff"] + flags
    case .staged: return ["diff"] + flags + ["--cached"]
    case .commit:
      let commit = try await commitID(selection, at: root)
      let lineage = try await checked(["rev-list", "--parents", "-n", "1", commit, "--"], at: root)
        .split(whereSeparator: \.isWhitespace).map(String.init)
      if lineage.count > 1 { return ["diff"] + flags + [lineage[1], commit] }
      return ["diff-tree", "--root", "--no-commit-id", "-r", "-p"] + flags + [commit]
    case .branch:
      let base = try await commitID(selection, at: root)
      let head = try await commitID("HEAD", at: root)
      let ancestor = try await checked(["merge-base", base, head], at: root)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return ["diff"] + flags + [ancestor, head]
    }
  }

  static func files(arguments: [String], at root: URL) async throws -> [GitFile] {
    let output = try await checked(arguments + ["--name-status", "-z", "--", "."], at: root)
    return GitFile.parseNameStatus(output)
  }

  static func modelReviewSnapshot(scope: ModelCodeReviewScope, at root: URL) async throws
    -> ModelCodeReviewSnapshot
  {
    let diff: String
    switch scope {
    case .uncommitted:
      diff = try await uncommittedDiff(at: root)
    case .branch(let selection):
      let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !selection.isEmpty else { throw AgentFailure(message: "请选择基础分支。") }
      let args = try await arguments(scope: .branch, selection: selection, at: root)
      diff = try await checked(args + ["--", "."], at: root)
    }
    guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentFailure(message: "没有可审查的更改。")
    }
    guard diff.utf8.count <= modelReviewMaximumBytes else {
      throw AgentFailure(message: "差异超过 512 KiB。请缩小更改范围后重试。")
    }
    return ModelCodeReviewSnapshot(scope: scope, diff: diff)
  }

  private static func uncommittedDiff(at root: URL) async throws -> String {
    let flags = [
      "--no-ext-diff", "--no-textconv", "--find-renames", "--src-prefix=a/",
      "--dst-prefix=b/", "--unified=3",
    ]
    let head = try await LocalWorkspaceService.git(
      ["rev-parse", "--verify", "HEAD"], at: root)
    var chunks: [String] = []
    if head.status == 0 {
      chunks.append(try await checked(["diff"] + flags + ["HEAD", "--", "."], at: root))
    } else {
      chunks.append(try await checked(["diff"] + flags + ["--cached", "--", "."], at: root))
      chunks.append(try await checked(["diff"] + flags + ["--", "."], at: root))
    }

    let untracked = try await checked(
      ["ls-files", "--others", "--exclude-standard", "-z"], at: root)
    for path in untracked.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
      let output = try await LocalWorkspaceService.git(
        ["diff", "--no-index"] + flags + ["--", "/dev/null", path], at: root)
      guard output.status == 0 || output.status == 1 else {
        throw AgentFailure(message: output.text)
      }
      chunks.append(output.text)
      if chunks.reduce(0, { $0 + $1.utf8.count }) > modelReviewMaximumBytes {
        throw AgentFailure(message: "差异超过 512 KiB。请缩小更改范围后重试。")
      }
    }
    return chunks.filter { !$0.isEmpty }.joined(separator: "\n")
  }
}
