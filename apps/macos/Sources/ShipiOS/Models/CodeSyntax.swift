import CryptoKit
import Foundation

struct CodeSyntaxIdentity: Hashable, Sendable {
  let path: String
  let fingerprint: String
  var wordDiffs = false
  func matchesSource(_ other: Self) -> Bool { path == other.path && fingerprint == other.fingerprint }
}
struct CodeSyntaxInput: Codable, Sendable {
  struct Line: Codable, Sendable {
    let id: Int
    let text: String
    let left: Bool
    let right: Bool
    let hunk: Int
    var hasNewline = true
  }
  let path: String
  let fingerprint: String
  let lines: [Line]
  var wordDiffs = false
  var identity: CodeSyntaxIdentity { .init(path: path, fingerprint: fingerprint, wordDiffs: wordDiffs) }
  init(_ file: GitHubPRCodeFile, wordDiffs: Bool = false) {
    self.init(path: file.path, diff: file.diff, wordDiffs: wordDiffs)
  }
  init(path: String, diff: ReviewDiff, wordDiffs: Bool = false) {
    self.path = path; fingerprint = diff.fingerprint
    self.wordDiffs = wordDiffs
    var hunk = 0
    let noEndings = Set(diff.lines.filter { $0.text.hasPrefix("\\ No newline") }.map { $0.id - 1 })
    lines = diff.lines.compactMap {
      if $0.kind == .header { hunk += 1 }
      guard $0.canComment else { return nil }
      return .init(id: $0.id, text: String($0.text.dropFirst()), left: $0.oldLine != nil, right: $0.newLine != nil,
        hunk: hunk, hasNewline: !noEndings.contains($0.id))
    }
  }
  /// Full source carries grammar state across every line, including blank lines.
  /// Its identity cannot alias a partial diff with the same file name.
  init(path: String, source: String) {
    self.path = path
    fingerprint = "source:" + SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    lines = source.components(separatedBy: "\n").enumerated().map {
      .init(id: $0.offset, text: $0.element, left: false, right: true, hunk: 0)
    }
  }
}
struct CodeSyntaxToken: Codable, Equatable, Sendable {
  struct Style: Codable, Equatable, Sendable {
    let color: String?
    let fontStyle: Int
    var valid: Bool {
      (0...7).contains(fontStyle) && (color == nil || color!.first == "#"
        && [7, 9].contains(color!.count) && color!.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit })
    }
  }
  let content: String
  let light: Style
  let dark: Style
}
struct CodeSyntaxResult: Codable, Equatable, Sendable {
  struct Row: Codable, Equatable, Sendable {
    let id: Int
    let tokens: [CodeSyntaxToken]
    var changes: [CodeWordRange] = []
  }
  let language: String
  let left: [Row]
  let right: [Row]
  func validate(_ input: CodeSyntaxInput) throws {
    guard !language.isEmpty, language.count <= 100,
      Set(input.lines.map(\.id)).count == input.lines.count else { throw invalid() }
    for (rows, expected) in [(left, input.lines.filter(\.left)), (right, input.lines.filter(\.right))] {
      guard rows.count == expected.count else { throw invalid() }
      for (row, line) in zip(rows, expected) {
        guard row.id == line.id, row.tokens.map(\.content).joined().utf8.elementsEqual(line.text.utf8),
          row.tokens.allSatisfy({ $0.light.valid && $0.dark.valid }),
          CodeWordRange.valid(row.changes, in: line.text),
          row.changes.isEmpty || input.wordDiffs,
          row.changes.isEmpty || line.left != line.right else { throw invalid() }
      }
    }
  }
  private func invalid() -> AgentFailure { .init(message: "代码高亮结果与当前差异不一致。") }
}
