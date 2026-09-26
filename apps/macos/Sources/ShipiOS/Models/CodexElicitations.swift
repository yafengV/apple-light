import Foundation

struct CodexElicitationField: Identifiable {
  enum Kind: Equatable { case text, integer, number, boolean, choice, multiChoice, json }
  let id: String
  let title: String
  let description: String
  let kind: Kind
  let required: Bool
  let secret: Bool
  let choices: [JSONValue]
  let choiceTitles: [String]
  let defaultValue: JSONValue?

  var defaultChoiceIndex: Int? {
    defaultValue.flatMap(choices.firstIndex(of:))
  }

  init(name: String, schema: JSONValue, required: Bool) {
    id = name
    title = schema["title"].text ?? name
    description = schema["description"].text ?? ""
    self.required = required
    secret = schema["format"].text == "password" || schema["writeOnly"].boolean == true
    defaultValue = schema["default"] == .null ? nil : schema["default"]
    let titled = schema["oneOf"].items
    let itemSchema = schema["items"]
    let multiTitled = itemSchema["anyOf"].items.isEmpty
      ? itemSchema["oneOf"].items : itemSchema["anyOf"].items
    if schema["type"].text == "array" && (!multiTitled.isEmpty || !itemSchema["enum"].items.isEmpty) {
      kind = .multiChoice
      choices = multiTitled.isEmpty ? itemSchema["enum"].items : multiTitled.map { $0["const"] }
      choiceTitles = multiTitled.isEmpty ? choices.map { $0.text ?? $0.pretty }
        : multiTitled.map { $0["title"].text ?? $0["const"].text ?? "" }
    } else if !titled.isEmpty || !schema["enum"].items.isEmpty {
      kind = .choice
      choices = titled.isEmpty ? schema["enum"].items : titled.map { $0["const"] }
      let legacyNames = schema["enumNames"].items.compactMap(\.text)
      choiceTitles = titled.isEmpty
        ? (legacyNames.count == choices.count ? legacyNames : choices.map { $0.text ?? $0.pretty })
        : titled.map { $0["title"].text ?? $0["const"].text ?? "" }
    } else {
      choices = []
      choiceTitles = []
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
  // URL requests may contain one-time tokens. Persist only the host for the timeline.
  var urlDisplay: String? = nil
  var status: Status = .awaiting

  var isURLRequest: Bool { urlDisplay != nil }

  static func parse(_ event: JSONValue) throws -> Self {
    let request = event["request"]
    guard event["type"].text == "elicitation_request",
      let serverName = event["server_name"].text, !serverName.isEmpty,
      let message = request["message"].text, !message.isEmpty,
      event["id"].text != nil || event["id"].int != nil else {
      throw AgentFailure(message: "Codex 返回了无效的 MCP 请求。")
    }
    if request["mode"].text == "url" {
      let url = try verificationURL(event)
      var record = Self(serverName: serverName, requestID: event["id"],
        message: message, schema: .null)
      record.urlDisplay = url.host.map { host in
        url.port.map { "\(host):\($0)" } ?? host
      }
      return record
    }
    guard event["type"].text == "elicitation_request",
      ["form", "openai/form", "openaiForm"].contains(request["mode"].text ?? ""),
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

  static func verificationURL(_ event: JSONValue) throws -> URL {
    let request = event["request"]
    guard request["mode"].text == "url",
      let id = request["elicitation_id"].text ?? request["elicitationId"].text,
      !id.isEmpty, id.utf8.count <= 256,
      let raw = request["url"].text, raw.utf8.count <= 4096,
      let parts = URLComponents(string: raw), let url = parts.url,
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil,
      parts.fragment == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true,
      parts.scheme?.lowercased() == "https" ||
        (parts.scheme?.lowercased() == "http" &&
          ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else {
      throw AgentFailure(message: "Codex 返回了无效的 MCP 验证地址。")
    }
    return url
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
    let enumValues = rule["oneOf"].items.isEmpty
      ? rule["enum"].items : rule["oneOf"].items.map { $0["const"] }
    if !enumValues.isEmpty && !enumValues.contains(value) { return false }
    switch rule["type"].text {
    case "string":
      guard let text = value.text else { return false }
      if let min = rule["minLength"].int, text.count < min { return false }
      if let max = rule["maxLength"].int, text.count > max { return false }
      switch rule["format"].text {
      case "email":
        if text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
          return false
        }
      case "uri":
        guard let parts = URLComponents(string: text), parts.scheme != nil,
          parts.url != nil else { return false }
      case "date":
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return false }
      case "date-time":
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: text) == nil {
          formatter.formatOptions = [.withInternetDateTime]
          guard formatter.date(from: text) != nil else { return false }
        }
      default: break
      }
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
      if case .object = rule["items"] {
        let itemRule = rule["items"]
        let titled = itemRule["anyOf"].items.isEmpty
          ? itemRule["oneOf"].items : itemRule["anyOf"].items
        let allowed = titled.isEmpty ? itemRule["enum"].items : titled.map { $0["const"] }
        if !allowed.isEmpty {
          guard items.allSatisfy({ allowed.contains($0) }),
            items.enumerated().allSatisfy({ index, item in
              !items.prefix(index).contains(item)
            }) else { return false }
        } else if !items.allSatisfy({ matches($0, rule: itemRule, depth: depth + 1) }) {
          return false
        }
      }
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
  let verificationURL: URL?
}

enum CodexElicitationChoice: String {
  case allow, allowForSession = "allow_for_session", deny, cancel

  init(_ decision: MCPApprovalDecision) {
    switch decision {
    case .allowOnce: self = .allow
    case .allowTask: self = .allowForSession
    case .deny: self = .deny
    }
  }
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
