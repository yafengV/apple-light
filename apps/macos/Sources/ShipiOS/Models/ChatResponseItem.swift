import Foundation

/// Ordered display events. Tool state lives in tool_executions and can change
/// without moving the corresponding row or replacing its view identity.
enum ChatResponseItem: Codable, Equatable, Identifiable, Sendable {
  case message(id: UUID, text: String)
  case tool(UUID)
  case question(UUID)

  var id: String {
    switch self {
    case .message(let id, _): "message." + id.uuidString
    case .tool(let id): "tool." + id.uuidString
    case .question(let id): "question." + id.uuidString
    }
  }
  var text: String? {
    if case .message(_, let text) = self { return text }
    return nil
  }
  var searchPrefix: String { "response." + id }

  static func append(_ delta: String, to items: inout [Self]) {
    guard !delta.isEmpty else { return }
    if case .message(let id, let text) = items.last {
      items[items.count - 1] = .message(id: id, text: text + delta)
    } else { items.append(.message(id: UUID(), text: delta)) }
  }

  static func json(_ items: [Self]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(items))
  }
}

extension AgentRun {
  var responseItems: [ChatResponseItem]? {
    guard let items = try? result?["response_items"].decode([ChatResponseItem].self),
      Set(items.map(\.id)).count == items.count else { return nil }
    let tools = items.compactMap { item -> UUID? in
      if case .tool(let id) = item { return id }
      return nil
    }
    let questions = items.compactMap { item -> UUID? in
      if case .question(let id) = item { return id }
      return nil
    }
    guard Set(tools) == Set(toolExecutions.map(\.id)) else { return nil }
    guard Set(questions) == Set(codexQuestions.map(\.id)) else { return nil }
    return items
  }

  /// Older records did not capture chronology. Keep their existing presentation
  /// rather than infer the position of a tool from its output or timestamps.
  var displayedResponseItems: [ChatResponseItem] {
    if let responseItems { return responseItems }
    return toolExecutions.map { .tool($0.id) } + [
      .message(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        text: result?["response"].text ?? "")]
  }
}
