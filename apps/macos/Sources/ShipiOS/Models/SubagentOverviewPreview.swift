import Foundation
import Markdown

enum SubagentOverviewPreview {
  /// Overview briefs describe the delegation. Final replies remain in history.
  static func text(for agent: CodexSubagent, liveEvents: [JSONValue] = []) -> String? {
    if let objective = agent.objective, let brief = objectiveText(objective) { return brief }
    if agent.overviewStatus == .active, let summary = reasoningSummary(liveEvents) { return summary }
    return agent.overviewStatus == .done ? nil : "正在工作"
  }

  static func objectiveText(_ source: String) -> String? {
    let source = source.replacingOccurrences(of: "\u{E200}[^\u{E201}]*\u{E201}", with: "", options: .regularExpression)
      .replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
    let plain = flatten(Document(parsing: source)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !plain.isEmpty else { return nil }
    guard plain.utf16.count > 60 else { return plain }
    // Match the reference's 59 UTF-16 units plus ellipsis, without emitting an
    // invalid surrogate when an emoji happens to cross the truncation boundary.
    var prefix = Array(plain.utf16.prefix(59))
    if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
    return String(decoding: prefix, as: UTF16.self).trimmingCharacters(in: .whitespaces) + "…"
  }

  private static func flatten(_ node: any Markup) -> String {
    if let code = node as? CodeBlock { return code.code }
    if let html = node as? HTMLBlock {
      return html.rawHTML.replacingOccurrences(of: #"<!--.*?-->|<[^>]+>"#, with: "", options: [.regularExpression])
    }
    if node is InlineHTML { return "" }
    if let leaf = node as? Text { return leaf.string }
    if let code = node as? InlineCode { return code.code }
    if node is SoftBreak || node is LineBreak { return " " }
    let separator = node is Document || node is BlockQuote || node is ListItem
      || node is OrderedList || node is UnorderedList || node is Table || node is Table.Row || node is Table.Cell ? " " : ""
    return node.children.map(flatten).joined(separator: separator)
  }

  private static func reasoningSummary(_ events: [JSONValue]) -> String? {
    guard let start = events.lastIndex(where: { ["task_started", "turn_started"].contains($0["type"].text ?? "") }) else { return nil }
    let transcript = SubagentTranscript(events: Array(events[start...]))
    guard transcript.activeTurnID != nil else { return nil }
    for entry in transcript.entries.reversed() where entry.kind == .reasoning {
      if let summary = normalizedReasoning(entry.text) { return summary }
    }
    return nil
  }

  static func normalizedReasoning(_ source: String) -> String? {
    var text = source.replacingOccurrences(of: #"^\s*(?:>\s*|#{1,6}\s+|(?:[-*+]|\d+\.)\s+)*"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "*", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    while text.count >= 2 {
      let before = text
      for marker in ["__", "_", "`"] where text.hasPrefix(marker) && text.hasSuffix(marker) && text.count > marker.count * 2 {
        text = String(text.dropFirst(marker.count).dropLast(marker.count)).trimmingCharacters(in: .whitespaces)
      }
      if text == before { break }
    }
    text = text.replacingOccurrences(of: #"^(?:i['’]m|i am)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
      .replacingOccurrences(of: #"[.!?;,:]+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    guard !text.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    if text.range(of: #"^\p{Lu}\p{Ll}"#, options: .regularExpression) != nil, let first = text.first {
      text = first.lowercased() + text.dropFirst()
    }
    return text
  }
}
