import Foundation

/// Core reasoning *summaries* are distinct from raw reasoning content. Only
/// summary deltas and section markers belong in the user-visible timeline.
enum CodexReasoningTimeline {
  static func apply(_ event: JSONValue, items: inout [ChatResponseItem]) -> Bool {
    guard let type = event["type"].text,
      type == "reasoning_content_delta" || type == "agent_reasoning_section_break",
      let itemID = event["item_id"].text, !itemID.isEmpty,
      let section = event["summary_index"].int, (0..<32).contains(section) else { return false }
    let delta = event["delta"].text ?? ""
    guard type != "reasoning_content_delta" || !delta.isEmpty else { return false }
    let index = items.firstIndex {
      if case .reasoning(let existing, _) = $0 { return existing == itemID }
      return false
    }
    guard type != "agent_reasoning_section_break" || index != nil else { return false }
    var sections: [String]
    if let index, case .reasoning(_, let existing) = items[index] { sections = existing }
    else { sections = [] }
    let previous = sections
    while sections.count <= section { sections.append("") }
    if type == "reasoning_content_delta" {
      let remaining = max(0, 65_536 - sections.reduce(0) { $0 + $1.utf8.count })
      guard remaining > 0 else { return false }
      sections[section] += String(decoding: Data(delta.utf8.prefix(remaining)), as: UTF8.self)
    }
    guard sections != previous else { return false }
    let item = ChatResponseItem.reasoning(itemID: itemID, sections: sections)
    if let index { items[index] = item }
    else { items.append(item) }
    return true
  }
}
