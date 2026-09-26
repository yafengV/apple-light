import Foundation

struct CodexElicitationField: Identifiable {
  enum Kind: Equatable { case text, integer, number, boolean, choice, json }
  let id: String
  let title: String
  let description: String
  let kind: Kind
  let required: Bool
  let secret: Bool
  let choices: [JSONValue]

  init(name: String, schema: JSONValue, required: Bool) {
    id = name
    title = schema["title"].text ?? name
    description = schema["description"].text ?? ""
    self.required = required
    secret = schema["format"].text == "password" || schema["writeOnly"].boolean == true
    choices = schema["enum"].items
    if !choices.isEmpty { kind = .choice }
    else {
      switch schema["type"].text {
      case "string": kind = .text
      case "integer": kind = .integer
      case "number": kind = .number
      case "boolean": kind = .boolean
      default: kind = .json
      }
    }
  }
}

struct CodexElicitationRequest: Codable, Equatable, Identifiable, Sendable {
  enum Status: String, Codable, Sendable { case awaiting, accepted, declined, cancelled, expired }
  var id = UUID()
  let serverName: String
  let requestID: JSONValue
  let message: String
  let schema: JSONValue
  var status: Status = .awaiting

  static func parse(_ event: JSONValue) throws -> Self {
    let request = event["request"]
    guard event["type"].text == "elicitation_request",
      ["form", "openai/form", "openaiForm"].contains(request["mode"].text ?? ""),
      let serverName = event["server_name"].text, !serverName.isEmpty,
      let message = request["message"].text, !message.isEmpty,
      event["id"].text != nil || event["id"].int != nil,
      case .object(let schema) = request["requested_schema"],
      schema["type"]?.text == "object",
      case .object(let properties) = schema["properties"], properties.count <= 32,
      properties.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
      properties.values.allSatisfy({ if case .object = $0 { true } else { false } }) else {
      throw AgentFailure(message: "Codex 返回了不支持的 MCP 表单。")
    }
    let required = Set((schema["required"]?.items ?? []).compactMap(\.text))
    guard required.isSubset(of: Set(properties.keys)) else {
      throw AgentFailure(message: "Codex MCP 表单的必填字段无效。")
    }
    return Self(serverName: serverName, requestID: event["id"], message: message,
      schema: request["requested_schema"])
  }

  var fields: [CodexElicitationField] {
    guard case .object(let properties) = schema["properties"] else { return [] }
    let required = Set(schema["required"].items.compactMap(\.text))
    return properties.keys.sorted().compactMap { name in
      properties[name].map { CodexElicitationField(name: name, schema: $0,
        required: required.contains(name)) }
    }
  }

  func validContent(_ content: JSONValue) -> Bool {
    guard case .object(let values) = content,
      case .object(let properties) = schema["properties"],
      Set(schema["required"].items.compactMap(\.text)).isSubset(of: Set(values.keys)),
      Set(values.keys).isSubset(of: Set(properties.keys)),
      (try? JSONEncoder().encode(content).count) ?? Int.max <= 65_536 else { return false }
    for (name, value) in values {
      guard let rule = properties[name], Self.matches(value, rule: rule, depth: 0) else { return false }
    }
    return true
  }

  private static func matches(_ value: JSONValue, rule: JSONValue, depth: Int) -> Bool {
    guard depth < 8 else { return false }
    if !rule["enum"].items.isEmpty && !rule["enum"].items.contains(value) { return false }
    switch rule["type"].text {
    case "string":
      guard let text = value.text else { return false }
      if let min = rule["minLength"].int, text.count < min { return false }
      if let max = rule["maxLength"].int, text.count > max { return false }
    case "integer":
      guard case .number(let number) = value, number.isFinite,
        number.rounded() == number, abs(number) <= 9_007_199_254_740_991 else { return false }
      if case .number(let minimum) = rule["minimum"], number < minimum { return false }
      if case .number(let maximum) = rule["maximum"], number > maximum { return false }
    case "number":
      guard case .number(let number) = value, number.isFinite else { return false }
      if case .number(let minimum) = rule["minimum"], number < minimum { return false }
      if case .number(let maximum) = rule["maximum"], number > maximum { return false }
    case "boolean":
      guard case .bool = value else { return false }
    case "array":
      guard case .array(let items) = value else { return false }
      if let minimum = rule["minItems"].int, items.count < minimum { return false }
      if let maximum = rule["maxItems"].int, items.count > maximum { return false }
      if case .object = rule["items"],
        !items.allSatisfy({ matches($0, rule: rule["items"], depth: depth + 1) }) { return false }
    case "object":
      guard case .object(let values) = value else { return false }
      if case .object(let properties) = rule["properties"] {
        let required = Set(rule["required"].items.compactMap(\.text))
        guard required.isSubset(of: Set(values.keys)),
          Set(values.keys).isSubset(of: Set(properties.keys)) else { return false }
        for (name, child) in values {
          guard let childRule = properties[name],
            matches(child, rule: childRule, depth: depth + 1) else { return false }
        }
      }
    case nil: break
    default: return false
    }
    return true
  }
}

struct CodexElicitationContext {
  let runID: String
  let taskID: String
  let request: CodexElicitationRequest
}

struct CodexElicitationDecision {
  let accepted: Bool
  let content: JSONValue?
}

extension AgentRun {
  var codexElicitations: [CodexElicitationRequest] {
    (try? result?["codex_elicitations"].decode([CodexElicitationRequest].self)) ?? []
  }
}
