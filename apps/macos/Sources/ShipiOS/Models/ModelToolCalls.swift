import Foundation

struct ModelFunctionCall: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let arguments: String
  var wire: JSONValue {
    .object(["id": .string(id), "type": .string("function"),
      "function": .object(["name": .string(name), "arguments": .string(arguments)])])
  }
}

struct ModelToolCallAccumulator {
  private var values: [Int: (id: String, name: String, arguments: String)] = [:]
  private var bytes = 0
  mutating func append(_ fragments: [JSONValue]) throws {
    for fragment in fragments {
      guard let index = fragment["index"].int, (0..<64).contains(index),
        fragment["type"] == .null || fragment["type"].text == "function" else {
        throw AgentFailure(message: "模型返回了无效工具调用。")
      }
      var value = values[index] ?? ("", "", "")
      let id = fragment["id"].text ?? ""
      let name = fragment["function"]["name"].text ?? ""
      let arguments = fragment["function"]["arguments"].text ?? ""
      bytes += id.utf8.count + name.utf8.count + arguments.utf8.count
      guard bytes <= 1_048_576 else { throw AgentFailure(message: "工具调用参数超过 1 MiB。") }
      value.id += id; value.name += name; value.arguments += arguments
      values[index] = value
    }
  }
  func completed(reason: String?) throws -> [ModelFunctionCall] {
    guard !values.isEmpty else { return [] }
    guard reason == "tool_calls" else { throw AgentFailure(message: "工具调用未完整生成，未执行。") }
    var ids = Set<String>()
    return try values.keys.sorted().map { index in
      let value = values[index]!
      guard !value.id.isEmpty, !value.name.isEmpty, ids.insert(value.id).inserted,
        case .object = try JSONDecoder().decode(JSONValue.self, from: Data(value.arguments.utf8)) else {
        throw AgentFailure(message: "工具调用标识或 JSON 参数无效，未执行。")
      }
      return ModelFunctionCall(id: value.id, name: value.name, arguments: value.arguments)
    }
  }
}

struct ModelTurnResult {
  let text: String
  let calls: [ModelFunctionCall]
  let usage: ModelTokenUsage?
}

enum MCPApprovalDecision { case allowOnce, allowTask, deny }

struct MCPToolExecution: Codable, Equatable, Identifiable {
  enum Status: String, Codable { case awaitingApproval, running, succeeded, failed, denied, cancelled }
  var id = UUID()
  let callID: String
  let serverID: UUID
  let serverName: String
  let toolName: String
  let arguments: String
  var status: Status = .awaitingApproval
  var output: String?
  var label: String {
    switch status {
    case .awaitingApproval: "等待批准"
    case .running: "正在执行"
    case .succeeded: "已完成"
    case .failed: "失败"
    case .denied: "已拒绝"
    case .cancelled: "已取消"
    }
  }
}

struct MCPToolBinding {
  let alias: String
  let serverID: UUID
  let serverName: String
  let connectionToken: UUID
  let tool: MCPToolDescription
  var wire: JSONValue {
    .object(["type": .string("function"), "function": .object([
      "name": .string(alias), "description": .string("\(serverName): \(tool.summary)"),
      "parameters": tool.inputSchema])])
  }
}

struct MCPApprovalContext {
  let runID: String
  let execution: MCPToolExecution
}

extension AgentRun {
  var toolExecutions: [MCPToolExecution] {
    (try? result?["tool_executions"].decode([MCPToolExecution].self)) ?? []
  }
}
