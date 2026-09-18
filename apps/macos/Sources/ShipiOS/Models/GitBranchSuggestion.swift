import Foundation

enum GitBranchSuggestion {
  static func name(prefix: String, title: String?) -> String {
    let suffix = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased().split(whereSeparator: \.isWhitespace).prefix(5).map { word in
        String(word.unicodeScalars.filter { (97...122).contains($0.value) || (48...57).contains($0.value) })
      }.filter { !$0.isEmpty }.joined(separator: "-")
    return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + suffix
  }
}
