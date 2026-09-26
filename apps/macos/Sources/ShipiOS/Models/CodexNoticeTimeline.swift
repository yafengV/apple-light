import Foundation

enum CodexNoticeTimeline {
  static func item(for event: JSONValue) -> ChatResponseItem? {
    guard let type = event["type"].text else { return nil }
    let kind: CodexNoticeKind
    let message: String
    switch type {
    case "warning", "guardian_warning":
      kind = .warning
      message = event["message"].text ?? ""
      if type == "guardian_warning",
        message.hasPrefix("Automatic approval review approved (") { return nil }
    case "deprecation_notice":
      kind = .deprecation
      let summary = event["summary"].text ?? ""
      let details = event["details"].text ?? ""
      message = details.isEmpty ? summary : summary + "\n\n" + details
    case "model_reroute":
      kind = .modelChange
      guard let from = event["from_model"].text, !from.isEmpty,
        let to = event["to_model"].text, !to.isEmpty else { return nil }
      message = "模型已从 \(from) 切换为 \(to)。"
    default: return nil
    }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return .notice(id: UUID(), kind: kind, message: String(trimmed.prefix(4096)))
  }
}
