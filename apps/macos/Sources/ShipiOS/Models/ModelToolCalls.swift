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

/// Projects the pinned Codex Core tool lifecycle onto the shared chat timeline.
/// Events are paired by call_id and tool kind; approval and completion update one row.
enum CodexCommandTimeline {
  static let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  static func apply(
    _ event: JSONValue, executions: inout [MCPToolExecution], items: inout [ChatResponseItem]
  ) -> Bool {
    guard let type = event["type"].text,
      ["exec_command_begin", "exec_command_end", "exec_approval_request",
        "patch_apply_begin", "patch_apply_end", "apply_patch_approval_request"].contains(type),
      let callID = event["call_id"].text, !callID.isEmpty else { return false }
    let patch = type.hasPrefix("patch_") || type == "apply_patch_approval_request"
    let toolName = patch ? "补丁" : "命令"
    let command = event["command"].items.compactMap(\.text).joined(separator: " ")
    let cwd = event["cwd"].text ?? ""
    let reason = event["reason"].text.map { "\n原因：\($0)" } ?? ""
    let arguments = patch ? String(event["changes"].pretty.prefix(65_536)) + reason
      : (cwd.isEmpty ? command : "\(cwd)\n$ \(command)") + reason
    let index = executions.firstIndex {
      $0.serverID == serverID && $0.callID == callID && $0.toolName == toolName
    }
    var execution = index.map { executions[$0] } ?? MCPToolExecution(
      callID: callID, serverID: serverID, serverName: "Codex", toolName: toolName,
      arguments: arguments, status: .running)
    if type == "exec_approval_request" || type == "apply_patch_approval_request" {
      execution.status = .awaitingApproval
    } else if type == "exec_command_begin" || type == "patch_apply_begin" {
      execution.status = .running
    } else if type == "exec_command_end" {
      let output = event["aggregated_output"].text.flatMap { $0.isEmpty ? nil : $0 }
        ?? [event["stdout"].text, event["stderr"].text].compactMap { $0 }.joined()
      execution.output = output.isEmpty ? nil : String(output.prefix(65_536))
      switch event["status"].text {
      case "declined": execution.status = .denied
      case "failed": execution.status = .failed
      default: execution.status = event["exit_code"].int == 0 ? .succeeded : .failed
      }
    } else if type == "patch_apply_end" {
      let output = [event["stdout"].text, event["stderr"].text].compactMap { $0 }.joined()
      execution.output = output.isEmpty ? nil : String(output.prefix(65_536))
      execution.status = event["success"].boolean == true ? .succeeded : .failed
    }
    if let index { executions[index] = execution }
    else {
      executions.append(execution)
      items.append(.tool(execution.id))
    }
    return true
  }

  static func resolve(
    callID: String, patch: Bool, allowed: Bool, executions: inout [MCPToolExecution]
  ) {
    guard let index = executions.firstIndex(where: {
      $0.serverID == serverID && $0.callID == callID && $0.toolName == (patch ? "补丁" : "命令")
    }) else { return }
    executions[index].status = allowed ? .running : .denied
    if !allowed { executions[index].output = "用户拒绝了本次操作。" }
  }
}
