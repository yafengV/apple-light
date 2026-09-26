import Foundation

struct CodexTurnDiff: Codable, Equatable, Identifiable {
  let id: UUID
  var unifiedDiff: String
  var truncated: Bool
  var changedFileCount: Int
  /// Nil for records created before full private diff snapshots were added.
  var storedByteCount: Int? = nil
  var contentSHA256: String? = nil
}

extension AgentRun {
  var codexTurnDiff: CodexTurnDiff? {
    try? result?["codex_turn_diff"].decode(CodexTurnDiff.self)
  }
}

enum CodexTurnDiffTimeline {
  static func apply(
    _ event: JSONValue, diff: inout CodexTurnDiff?, items: inout [ChatResponseItem],
    storedByteCount: Int? = nil, contentSHA256: String? = nil, newID: UUID? = nil
  ) -> Bool {
    guard event["type"].text == "turn_diff",
      let source = event["unified_diff"].text else { return false }
    if source.isEmpty {
      guard let previous = diff else { return false }
      items.removeAll { $0 == .diff(previous.id) }
      diff = nil
      return true
    }
    let fileCount = source.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.count
    let limited = String(source.prefix(262_144))
    let truncated = source.count > 262_144
    if let previous = diff {
      guard previous.unifiedDiff != limited || previous.truncated != truncated
        || previous.changedFileCount != fileCount || previous.storedByteCount != storedByteCount
        || previous.contentSHA256 != contentSHA256 else { return false }
      diff = CodexTurnDiff(id: previous.id, unifiedDiff: limited, truncated: truncated,
        changedFileCount: fileCount, storedByteCount: storedByteCount,
        contentSHA256: contentSHA256)
    } else {
      let created = CodexTurnDiff(id: newID ?? UUID(), unifiedDiff: limited, truncated: truncated,
        changedFileCount: fileCount, storedByteCount: storedByteCount,
        contentSHA256: contentSHA256)
      diff = created
      items.append(.diff(created.id))
    }
    return true
  }
}
