import CryptoKit
import Foundation

struct ReviewDiffLine: Identifiable, Equatable, Sendable {
  enum Kind: Sendable { case header, context, addition, deletion, metadata }
  let id: Int
  let text: String
  let kind: Kind
  let oldLine: Int?
  let newLine: Int?
  var workingLine: Int? = nil
  var canComment: Bool { oldLine != nil || newLine != nil }
  func displayText(markerStyle: DiffMarkerStyle) -> String {
    guard markerStyle == .color, kind == .addition || kind == .deletion else {
      return text.isEmpty ? " " : text
    }
    let content = String(text.dropFirst())
    return content.isEmpty ? " " : content
  }
}

struct ReviewDiff: Sendable {
  let lines: [ReviewDiffLine]
  let fingerprint: String
  var additions: Int { lines.filter { $0.kind == .addition }.count }
  var deletions: Int { lines.filter { $0.kind == .deletion }.count }

  init(_ patch: String) {
    fingerprint = SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
    var old = 0
    var new = 0
    var remainingOld = 0
    var remainingNew = 0
    var result: [ReviewDiffLine] = []
    var source = patch.components(separatedBy: "\n")
    if source.last == "" { source.removeLast() }
    for (index, text) in source.enumerated() {
      var kind = ReviewDiffLine.Kind.metadata
      var left: Int?
      var right: Int?
      if text.hasPrefix("@@ ") {
        let pieces = text.split(separator: " ")
        if pieces.count >= 4, pieces[3] == "@@",
          let lhs = Self.range(pieces[1], prefix: "-"), let rhs = Self.range(pieces[2], prefix: "+")
        {
          (old, remainingOld) = lhs
          (new, remainingNew) = rhs
          kind = .header
        } else {
          remainingOld = 0
          remainingNew = 0
        }
      } else if text.hasPrefix("-"), remainingOld > 0 {
        kind = .deletion
        left = old
        old += 1
        remainingOld -= 1
      } else if text.hasPrefix("+"), remainingNew > 0 {
        kind = .addition
        right = new
        new += 1
        remainingNew -= 1
      } else if text.hasPrefix(" "), remainingOld > 0, remainingNew > 0 {
        kind = .context
        left = old
        right = new
        old += 1
        new += 1
        remainingOld -= 1
        remainingNew -= 1
      }
      result.append(
        .init(
          id: index, text: text, kind: kind, oldLine: left, newLine: right,
          workingLine: right ?? (left != nil ? max(1, new) : nil)))
    }
    lines = result
  }

  private static func range(_ text: Substring, prefix: Character) -> (Int, Int)? {
    guard text.first == prefix else { return nil }
    let fields = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
    guard (1...2).contains(fields.count), let start = Int(fields[0]), start >= 0,
      let count = fields.count == 1 ? 1 : Int(fields[1]), count >= 0,
      start <= Int.max - count
    else { return nil }
    return (start, count)
  }

  static func untracked(_ content: String) -> Self {
    var lines = content.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    guard !lines.isEmpty else { return Self("空文件\n") }
    return Self("@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n"))
  }
}

struct ReviewAnchor: Codable, Equatable {
  let project: String
  let path: String
  let scope: String
  let revision: String
  let fingerprint: String
  let oldLine: Int?
  let newLine: Int?
  let code: String
  var oldPath: String? = nil
  var location: String {
    if let newLine { return "新文件第 \(newLine) 行" }
    return "旧文件第 \(oldLine ?? 0) 行"
  }
}

struct ReviewComment: Codable, Identifiable, Equatable {
  var id = UUID()
  let anchor: ReviewAnchor
  var body = ""
  var editingText: String? = ""
}
