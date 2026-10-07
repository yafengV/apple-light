import Foundation

struct SubagentTranscriptEntry: Identifiable, Equatable {
  enum Kind: Equatable { case user, assistant, reasoning, tool, notice, approval, elicitation }
  let id: String
  let kind: Kind
  let title: String?
  var text: String
  var approval: SubagentApprovalRequest? = nil
  var elicitation: SubagentElicitationRequest? = nil
  var localImagePaths: [String] = []
  var turnID: String? = nil
  var images: [ImageAttachment] = []
  var files: [FileAttachment] = []
  var hasAttachmentMetadata = false
}

struct SubagentTranscript: Equatable {
  var entries: [SubagentTranscriptEntry] = []
  var activeTurnID: String?

  init(events: [JSONValue] = []) {
    // Choose each turn's native presentation family independently. Older
    // durable turns can use raw messages while current turns have legacy/items.
    var scopes: [String] = [], scope = "before-turn"
    var nativeTurns: [String?] = [], nativeTurn: String?
    var legacyUsers: Set<String> = [], legacyAssistants: Set<String> = []
    var legacyReasoning: Set<String> = []
    var nativeUsers: Set<String> = [], nativeAssistants: Set<String> = []
    for event in events {
      if ["task_started", "turn_started"].contains(event["type"].text ?? "") {
        nativeTurn = event["turn_id"].text
        scope = nativeTurn ?? "turn-" + String(scopes.count)
      }
      scopes.append(scope); nativeTurns.append(nativeTurn)
      if event["type"].text == "user_message" { legacyUsers.insert(scope); nativeUsers.insert(scope) }
      if event["type"].text == "agent_reasoning" { legacyReasoning.insert(scope) }
      if event["type"].text == "agent_message" { legacyAssistants.insert(scope); nativeAssistants.insert(scope) }
      if event["type"].text == "item_completed", event["item"]["type"].text == "UserMessage" { nativeUsers.insert(scope) }
      if event["type"].text == "item_completed", event["item"]["type"].text == "AgentMessage" { nativeAssistants.insert(scope) }
    }
    var pendingAssistant: [String: Int] = [:], pendingReasoning: [String: Int] = [:]
    var pendingCommands: [String: Int] = [:]
    var toolNames: [String: String] = [:]
    for (index, event) in events.enumerated() {
      let scope = scopes[index]
      func replace(_ at: Int, with text: String) {
        let old = entries[at]
        entries[at] = .init(id: old.id, kind: old.kind, title: old.title, text: text)
      }
      func streamed(_ key: String, _ text: String, kind: SubagentTranscriptEntry.Kind,
        title: String?, into pending: inout [String: Int], final: Bool = false) {
        if let at = pending[key] { replace(at, with: final ? text : entries[at].text + text) }
        else {
          guard !text.isEmpty else { return }
          pending[key] = entries.count
          entries.append(.init(id: String(index), kind: kind, title: title, text: text))
        }
        if final { pending.removeValue(forKey: key) }
      }
      func append(_ kind: SubagentTranscriptEntry.Kind, _ text: String?, title: String? = nil) {
        guard let text, !text.isEmpty else { return }
        entries.append(.init(id: String(index), kind: kind, title: title, text: text))
      }
      func user(_ text: String?, images: [String]) {
        let text = text ?? ""
        guard !text.isEmpty || !images.isEmpty else { return }
        entries.append(.init(id: String(index), kind: .user, title: nil, text: text, localImagePaths: images, turnID: nativeTurns[index]))
      }
      switch event["type"].text {
      case "task_started", "turn_started":
        activeTurnID = event["turn_id"].text
        pendingAssistant = [:]; pendingReasoning = [:]; pendingCommands = [:]
      case "task_complete", "turn_aborted":
        if event["turn_id"].text == nil || event["turn_id"].text == activeTurnID { activeTurnID = nil }
      case "user_message": user(event["message"].text, images: event["local_images"].decodeArray.compactMap(\.text))
      case "agent_message_content_delta", "agent_message_delta":
        guard event["turn_id"].text == nil || event["turn_id"].text == activeTurnID,
          let delta = event["delta"].text else { continue }
        streamed(event["item_id"].text ?? "legacy", delta, kind: .assistant, title: nil, into: &pendingAssistant)
      case "agent_message":
        if let text = event["message"].text, let key = pendingAssistant.max(by: { $0.value < $1.value })?.key {
          streamed(key, text, kind: .assistant, title: nil, into: &pendingAssistant, final: true)
        } else { append(.assistant, event["message"].text) }
      case "reasoning_content_delta":
        guard event["turn_id"].text == nil || event["turn_id"].text == activeTurnID,
          let delta = event["delta"].text else { continue }
        let key = (event["item_id"].text ?? "reasoning") + ":" + String(event["summary_index"].int ?? 0)
        streamed(key, delta, kind: .reasoning, title: "思考摘要", into: &pendingReasoning)
      case "exec_command_begin":
        let command = event["command"].decodeArray.compactMap(\.text).joined(separator: " ")
        streamed(event["call_id"].text ?? String(index), command, kind: .tool, title: "命令", into: &pendingCommands)
      case "exec_command_output_delta":
        if let chunk = event["chunk"].text {
          streamed(event["call_id"].text ?? "command", chunk, kind: .tool, title: "命令输出", into: &pendingCommands)
        }
      case "exec_command_end":
        streamed(event["call_id"].text ?? "command", event["aggregated_output"].text ?? "",
          kind: .tool, title: "命令输出", into: &pendingCommands, final: true)
      case "error", "warning": append(.notice, event["message"].text)
      case "exec_approval_request", "apply_patch_approval_request":
        if let approval = SubagentApprovalRequest(event) {
          entries.append(.init(id: "approval:" + approval.id, kind: .approval, title: approval.title, text: "", approval: approval))
        } else { append(.notice, "历史审批记录", title: "审批") }
      case "elicitation_request":
        if let request = SubagentElicitationRequest(event) {
          entries.append(.init(id: "elicitation:" + request.id, kind: .elicitation, title: "MCP", text: "", elicitation: request))
        } else { append(.notice, "MCP 请求已结束或暂不支持此表单。", title: "MCP") }
      case "request_user_input": append(.notice, "子任务正在等待操作。", title: "等待")
      case "agent_reasoning":
        if let text = event["text"].text, let key = pendingReasoning.max(by: { $0.value < $1.value })?.key {
          streamed(key, text, kind: .reasoning, title: "思考摘要", into: &pendingReasoning, final: true)
        } else { append(.reasoning, event["text"].text, title: "思考摘要") }
      case "context_compacted": append(.notice, "上下文已整理")
      case "raw_response_item":
        let item = event["item"]
        switch item["type"].text {
        case "message":
          let role = item["role"].text
          guard role == "user" && !nativeUsers.contains(scope) || role == "assistant" && !nativeAssistants.contains(scope) else { continue }
          let parts = item["content"].decodeArray
          let text = parts.compactMap { $0["text"].text }.joined(separator: "\n")
          if role == "user" { user(text, images: []) } else { append(.assistant, text) }
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
        case "UserMessage":
          guard !legacyUsers.contains(scope) else { continue }
          let parts = item["content"].decodeArray
          user(parts.compactMap { $0["text"].text }.joined(separator: "\n"),
            images: parts.filter { $0["type"].text == "local_image" }.compactMap { $0["path"].text })
        case "AgentMessage":
          guard !legacyAssistants.contains(scope) else { continue }
          let text = item["content"].decodeArray.compactMap { $0["text"].text }.joined(separator: "\n")
          streamed(item["id"].text ?? "legacy", text, kind: .assistant, title: nil, into: &pendingAssistant, final: true)
        case "Reasoning":
          guard !legacyReasoning.contains(scope) else { continue }
          for (section, text) in item["summary_text"].decodeArray.compactMap(\.text).enumerated() {
            streamed((item["id"].text ?? "reasoning") + ":" + String(section), text,
              kind: .reasoning, title: "思考摘要", into: &pendingReasoning, final: true)
          }
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
