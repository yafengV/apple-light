import Foundation

struct CodeSyntaxIdentity: Hashable, Sendable {
  let path: String
  let fingerprint: String
}
struct CodeSyntaxInput: Codable, Sendable {
  struct Line: Codable, Sendable {
    let id: Int
    let text: String
    let left: Bool
    let right: Bool
    let hunk: Int
  }
  let path: String
  let fingerprint: String
  let lines: [Line]
  var identity: CodeSyntaxIdentity { .init(path: path, fingerprint: fingerprint) }
  init(_ file: GitHubPRCodeFile) {
    path = file.path; fingerprint = file.diff.fingerprint
    var hunk = 0
    lines = file.diff.lines.compactMap {
      if $0.kind == .header { hunk += 1 }
      guard $0.canComment else { return nil }
      return .init(id: $0.id, text: String($0.text.dropFirst()), left: $0.oldLine != nil, right: $0.newLine != nil, hunk: hunk)
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
        guard row.id == line.id, row.tokens.map(\.content).joined() == line.text,
          row.tokens.allSatisfy({ $0.light.valid && $0.dark.valid }) else { throw invalid() }
      }
    }
  }
  private func invalid() -> AgentFailure { .init(message: "代码高亮结果与当前差异不一致。") }
}
