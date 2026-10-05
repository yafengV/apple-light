import Foundation

struct SubagentTranscriptEntry: Identifiable, Equatable {
  enum Kind: Equatable { case user, assistant, reasoning, tool, notice }
  let id: String
  let kind: Kind
  let title: String?
  let text: String
}

struct SubagentTranscript: Equatable {
  var entries: [SubagentTranscriptEntry] = []
  var activeTurnID: String?

  init(events: [JSONValue] = []) {
    // Legacy events and paginated TurnItems duplicate raw response messages.
    // Prefer presentation messages whenever that role has native records.
    let hasUser = events.contains { $0["type"].text == "user_message" || ($0["type"].text == "item_completed" && $0["item"]["type"].text == "UserMessage") }
    let hasAssistant = events.contains { $0["type"].text == "agent_message" || ($0["type"].text == "item_completed" && $0["item"]["type"].text == "AgentMessage") }
    var toolNames: [String: String] = [:]
    for (index, event) in events.enumerated() {
      func append(_ kind: SubagentTranscriptEntry.Kind, _ text: String?, title: String? = nil) {
        guard let text, !text.isEmpty else { return }
        entries.append(.init(id: String(index), kind: kind, title: title, text: text))
      }
      switch event["type"].text {
      case "task_started", "turn_started": activeTurnID = event["turn_id"].text
      case "task_complete", "turn_aborted":
        if event["turn_id"].text == nil || event["turn_id"].text == activeTurnID { activeTurnID = nil }
      case "user_message": append(.user, event["message"].text)
      case "agent_message": append(.assistant, event["message"].text)
      case "agent_reasoning": append(.reasoning, event["text"].text, title: "思考摘要")
      case "context_compacted": append(.notice, "上下文已整理")
      case "raw_response_item":
        let item = event["item"]
        switch item["type"].text {
        case "message":
          let role = item["role"].text
          guard role == "user" && !hasUser || role == "assistant" && !hasAssistant else { continue }
          let parts = item["content"].decodeArray
          append(role == "user" ? .user : .assistant, parts.compactMap { $0["text"].text }.joined(separator: "\n"))
        case "function_call", "custom_tool_call":
          let id = item["call_id"].text ?? "", name = item["name"].text ?? "工具"
          toolNames[id] = name
          append(.tool, item["arguments"].text ?? item["input"].text, title: name)
        case "function_call_output", "custom_tool_call_output":
          let output = item["output"]
          let text = output.text ?? (output == .null ? nil : output.pretty)
          append(.tool, text, title: toolNames[item["call_id"].text ?? ""] ?? "工具输出")
        case "reasoning":
          append(.reasoning, item["summary"].decodeArray.compactMap { $0["text"].text }.joined(separator: "\n"), title: "思考摘要")
        default: break
        }
      case "item_completed":
        let item = event["item"]
        switch item["type"].text {
        case "UserMessage": append(.user, item["content"].decodeArray.compactMap { $0["text"].text }.joined(separator: "\n"))
        case "AgentMessage": append(.assistant, item["content"].decodeArray.compactMap { $0["text"].text }.joined(separator: "\n"))
        case "Reasoning": append(.reasoning, item["summary_text"].decodeArray.compactMap(\.text).joined(separator: "\n"), title: "思考摘要")
        case "CommandExecution":
          append(.tool, item["aggregated_output"].text ?? item["command"].decodeArray.compactMap(\.text).joined(separator: " "), title: "命令")
        case "FunctionCallOutput":
          append(.tool, item["output"].text ?? item["output"].pretty, title: item["name"].text ?? "工具输出")
        default: break
        }
      default: break
      }
    }
  }
}

private extension JSONValue {
  var decodeArray: [JSONValue] { if case .array(let values) = self { values } else { [] } }
}
