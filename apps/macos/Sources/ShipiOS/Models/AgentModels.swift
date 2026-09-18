import Foundation

enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let value = try? c.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? c.decode(String.self) {
      self = .string(value)
    } else if let value = try? c.decode(Double.self) {
      self = .number(value)
    } else if let value = try? c.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let x): try c.encode(x)
    case .array(let x): try c.encode(x)
    case .string(let x): try c.encode(x)
    case .number(let x): try c.encode(x)
    case .bool(let x): try c.encode(x)
    case .null: try c.encodeNil()
    }
  }
  subscript(_ key: String) -> JSONValue {
    if case .object(let x) = self { return x[key] ?? .null }
    return .null
  }
  var text: String? {
    if case .string(let x) = self { return x }
    return nil
  }
  var int: Int? {
    if case .number(let x) = self { return Int(exactly: x) }
    return nil
  }
  var boolean: Bool? {
    if case .bool(let x) = self { return x }
    return nil
  }
  var items: [JSONValue] {
    if case .array(let x) = self { return x }
    return []
  }
  var pretty: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? ""
  }
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

struct AgentRun: Codable, Identifiable, Equatable {
  let id: String
  let kind: String
  let project: String
  let status: String
  let createdAt: Double
  let updatedAt: Double
  let request: JSONValue
  let result: JSONValue?
  var isActive: Bool { ["queued", "running"].contains(status) }
  var title: String {
    if kind == "chat" {
      let model = request["model"].text ?? "模型会话"
      if request["conversation_kind"].text == "review" { return "代码审查 · \(model)" }
      switch ChatMode(rawValue: request["mode"].text ?? "") ?? .standard {
      case .standard: return model
      case .plan: return "计划 · \(model)"
      case .goal: return "目标 · \(model)"
      }
    }
    return kind == "doctor" ? "环境诊断" : "构建 · \(request["scheme"].text ?? "项目")"
  }
  var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
  var statusLabel: String {
    switch status {
    case "queued": return "等待中"
    case "running": return "运行中"
    case "succeeded": return "已完成"
    case "failed": return "失败"
    case "cancelled": return "已取消"
    case "interrupted": return "已中断"
    default: return status
    }
  }
}

struct ProjectInspection: Codable {
  let root: String
  let containers: [String]
  let swiftPackages: [String]
  let diagnostics: [String]
  let scanTruncated: Bool
}

struct AgentEvent: Codable, Identifiable {
  let runId: String
  let sequence: Int
  let timestamp: Double
  let kind: String
  let payload: JSONValue
  var id: String { "\(runId):\(sequence)" }
  var title: String {
    switch kind {
    case "run.queued": return "任务已创建"
    case "run.started": return "开始执行"
    case "step.started": return "执行 Xcode 命令"
    case "run.completed": return "任务结束"
    default: return kind
    }
  }
}

struct AgentFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Parses fragmented JSONL and rejects unbounded output from a broken helper.
struct FrameDecoder {
  var buffer = Data()
  mutating func append(_ data: Data) throws -> [JSONValue] {
    buffer.append(data)
    var frames: [JSONValue] = []
    while let newline = buffer.firstIndex(of: 10) {
      guard buffer.distance(from: buffer.startIndex, to: newline) <= 16 * 1024 * 1024 else {
        throw AgentFailure(message: "Agent 响应超过大小限制")
      }
      let frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if !frame.isEmpty { frames.append(try JSONDecoder().decode(JSONValue.self, from: frame)) }
    }
    guard buffer.count <= 16 * 1024 * 1024 else { throw AgentFailure(message: "Agent 响应超过大小限制") }
    return frames
  }
}
