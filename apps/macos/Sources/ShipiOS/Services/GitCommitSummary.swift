import Foundation

struct GitCommitSummary: Equatable, Sendable {
  var files = 0
  var additions = 0
  var deletions = 0
  var binaryFiles = 0
  var hasChanges: Bool { files > 0 }

  static func capture(at root: URL, includeUnstaged: Bool) async throws -> Self {
    let top = try await GitReviewService.checked(["rev-parse", "--show-toplevel"], at: root)
      .trimmingCharacters(in: .newlines)
    guard GitBranchService.canonicalRoot(URL(fileURLWithPath: top)) == GitBranchService.canonicalRoot(root) else {
      throw AgentFailure(message: "请打开仓库根目录后预览提交范围。")
    }
    return try await GitCommitIndex.withSelection(at: root, includeUnstaged: includeUnstaged) { index in
      let output = try await LocalWorkspaceService.git([
        "diff", "--cached", "--numstat", "-z", "--find-renames", "--no-ext-diff", "--no-textconv", "--",
      ], at: root, indexFile: index)
      guard output.status == 0 else { throw AgentFailure(message: output.text) }
      try Task.checkCancellation()
      return try parse(output.text)
    }
  }

  static func parse(_ text: String) throws -> Self {
    if text.isEmpty { return Self() }
    let records = text.split(separator: "\0", omittingEmptySubsequences: false)
    guard records.last?.isEmpty == true else { throw AgentFailure(message: "Git 变更统计不完整。") }
    var result = Self(), cursor = 0
    while cursor < records.count - 1 {
      let fields = records[cursor].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      cursor += 1
      guard fields.count == 3 else { throw AgentFailure(message: "无法读取 Git 变更统计。") }
      if fields[2].isEmpty {
        guard cursor + 1 < records.count - 1, !records[cursor].isEmpty, !records[cursor + 1].isEmpty else {
          throw AgentFailure(message: "Git 重命名统计不完整。")
        }
        cursor += 2
      }
      result.files += 1
      if fields[0] == "-", fields[1] == "-" { result.binaryFiles += 1; continue }
      guard let added = Int(fields[0]), let removed = Int(fields[1]), added >= 0, removed >= 0 else {
        throw AgentFailure(message: "Git 行数统计无效。")
      }
      let (additions, aOverflow) = result.additions.addingReportingOverflow(added)
      let (deletions, dOverflow) = result.deletions.addingReportingOverflow(removed)
      guard !aOverflow, !dOverflow else { throw AgentFailure(message: "Git 行数统计超出支持范围。") }
      result.additions = additions; result.deletions = deletions
    }
    return result
  }
}
