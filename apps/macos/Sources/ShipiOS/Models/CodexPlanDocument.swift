import Foundation

/// A completed plan response item, distinct from update_plan progress steps.
struct CodexPlanDocument: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let text: String

  static func completed(_ event: JSONValue) -> Self? {
    guard event["type"].text == "item_completed",
      event["item"]["type"].text == "plan",
      let id = event["item"]["id"].text, !id.isEmpty, id.utf8.count <= 256,
      let text = event["item"]["text"].text, !text.isEmpty,
      text.utf8.count <= 1_048_576 else { return nil }
    return Self(id: id, text: text)
  }

  var title: String {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("# ") {
        let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if !heading.isEmpty { return String(heading.prefix(120)) }
      }
    }
    return "计划"
  }
}

extension AgentRun {
  var codexPlanDocument: CodexPlanDocument? {
    try? result?["codex_plan_document"].decode(CodexPlanDocument.self)
  }
}
