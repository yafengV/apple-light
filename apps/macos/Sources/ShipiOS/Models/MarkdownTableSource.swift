import Foundation
import Markdown

enum MarkdownTableSource {
  /// Parser columns are UTF-8 byte offsets. Preserve table syntax, while
  /// excluding surrounding list/quote prefixes from subsequent source lines.
  static func extract(_ table: Markdown.Table, from source: String) -> String {
    guard let range = table.range else { return JavaScriptText.trimmed(table.format()) }
    // Swift treats CRLF as one Character, so splitting on the LF Character
    // alone would leave the entire document on one line and lose raw syntax.
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.utf8) }
    let first = range.lowerBound.line - 1, last = range.upperBound.line - 1
    guard first >= 0, last >= first, lines.indices.contains(last) else { return JavaScriptText.trimmed(table.format()) }
    let indent = max(0, range.lowerBound.column - 1)
    var result: [String] = []
    for line in first...last {
      let bytes = lines[line]
      let end = line == last ? min(bytes.count, max(0, range.upperBound.column - 1)) : bytes.count
      var start = line == first ? min(indent, end) : 0
      if line > first {
        // Lazy quote continuation lines may omit the quote marker entirely.
        while start < min(indent, end), [9, 32, 62].contains(bytes[start]) { start += 1 }
      }
      result.append(String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
    }
    return JavaScriptText.trimmed(result.joined(separator: "\n"))
  }
}
