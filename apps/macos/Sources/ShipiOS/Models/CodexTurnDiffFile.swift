import Foundation

/// A navigation slice of Core's exact cumulative unified diff.
struct CodexTurnDiffFile: Identifiable, Equatable {
  let id: Int
  let path: String
  let patch: String
}

enum CodexTurnDiffFiles {
  static func parse(_ source: String) -> [CodexTurnDiffFile] {
    let lines = source.components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0].hasPrefix("diff --git ") }
    guard !starts.isEmpty else {
      return source.isEmpty ? [] : [.init(id: 0, path: "完整差异", patch: source)]
    }
    return starts.enumerated().map { position, start in
      let end = position + 1 < starts.count ? starts[position + 1] : lines.count
      let patchStart = position == 0 ? 0 : start
      var patch = lines[patchStart..<end].joined(separator: "\n")
      if end < lines.count { patch += "\n" }
      return .init(id: position, path: path(in: lines[start..<end]) ?? "文件 \(position + 1)",
        patch: patch)
    }
  }

  private static func path(in lines: ArraySlice<String>) -> String? {
    var oldPath: String?
    var newPath: String?
    var renamePath: String?
    for line in lines.dropFirst() {
      if line.hasPrefix("@@ ") || line == "GIT binary patch"
        || line.hasPrefix("Binary files ") { break }
      if line.hasPrefix("--- ") { oldPath = markerPath(String(line.dropFirst(4))) }
      else if line.hasPrefix("+++ ") { newPath = markerPath(String(line.dropFirst(4))) }
      else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
        renamePath = decodeGitPath(String(line.dropFirst(line.hasPrefix("rename") ? 10 : 8)))
      }
    }
    if let newPath { return newPath }
    if let renamePath { return renamePath }
    if let oldPath { return oldPath }
    guard let header = lines.first else { return nil }
    let tokens = gitTokens(String(header.dropFirst("diff --git ".count)))
    return tokens.last.flatMap { markerPath($0) }
  }

  private static func markerPath(_ raw: String) -> String? {
    let value = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? raw
    guard let decoded = decodeGitPath(value), decoded != "/dev/null" else { return nil }
    if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
      return String(decoded.dropFirst(2))
    }
    return decoded
  }

  private static func gitTokens(_ source: String) -> [String] {
    let bytes = Array(source.utf8)
    var tokens: [String] = []
    var cursor = 0
    while cursor < bytes.count {
      while cursor < bytes.count && bytes[cursor] == 32 { cursor += 1 }
      guard cursor < bytes.count else { break }
      let start = cursor
      if bytes[cursor] == 34 {
        cursor += 1
        while cursor < bytes.count {
          if bytes[cursor] == 92 { cursor += min(2, bytes.count - cursor) }
          else if bytes[cursor] == 34 { cursor += 1; break }
          else { cursor += 1 }
        }
      } else {
        while cursor < bytes.count && bytes[cursor] != 32 { cursor += 1 }
      }
      tokens.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
    }
    return tokens
  }

  private static func decodeGitPath(_ raw: String) -> String? {
    let bytes = Array(raw.utf8)
    guard bytes.first == 34 else { return raw }
    guard bytes.count >= 2, bytes.last == 34 else { return nil }
    var decoded: [UInt8] = []
    var cursor = 1
    while cursor < bytes.count - 1 {
      let byte = bytes[cursor]
      guard byte == 92 else { decoded.append(byte); cursor += 1; continue }
      cursor += 1
      guard cursor < bytes.count - 1 else { return nil }
      let escaped = bytes[cursor]
      if cursor + 2 < bytes.count - 1,
        (48...55).contains(escaped), (48...55).contains(bytes[cursor + 1]),
        (48...55).contains(bytes[cursor + 2]) {
        let value = Int(escaped - 48) * 64 + Int(bytes[cursor + 1] - 48) * 8
          + Int(bytes[cursor + 2] - 48)
        guard value <= 255 else { return nil }
        decoded.append(UInt8(value))
        cursor += 3
        continue
      }
      switch escaped {
      case 34, 92: decoded.append(escaped)
      case 97: decoded.append(7)
      case 98: decoded.append(8)
      case 102: decoded.append(12)
      case 110: decoded.append(10)
      case 114: decoded.append(13)
      case 116: decoded.append(9)
      case 118: decoded.append(11)
      default: return nil
      }
      cursor += 1
    }
    return String(bytes: decoded, encoding: .utf8)
  }
}
