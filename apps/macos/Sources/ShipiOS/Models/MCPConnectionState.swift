import Foundation

struct MCPToolDescription: Identifiable, Equatable {
  var id: String { name }
  let name: String
  let title: String
  let summary: String
  let inputSchema: JSONValue
}

enum MCPConnectionState: Equatable {
  case disconnected, connecting, connected(String, [MCPToolDescription]), failed(String)
  var label: String {
    switch self {
    case .disconnected: "未连接"
    case .connecting: "正在连接…"
    case .connected(_, let tools): "已连接 · \(tools.count) 个工具"
    case .failed: "连接失败"
    }
  }
  var tools: [MCPToolDescription] {
    if case .connected(_, let tools) = self { return tools }
    return []
  }
}

@MainActor protocol MCPWire: AnyObject {
  var protocolVersion: String? { get set }
  func send(_ message: JSONValue) async throws -> JSONValue
  func close() async
}

enum MCPMessages {
  static func result(_ response: JSONValue, id: JSONValue) throws -> JSONValue {
    guard response["jsonrpc"].text == "2.0", response["id"] == id else {
      throw AgentFailure(message: "MCP 返回了无效的响应标识。")
    }
    if response["error"] != .null {
      throw AgentFailure(message: "MCP 请求失败（\(response["error"]["code"].int ?? -1)）。")
    }
    guard case .object(let fields) = response, let result = fields["result"] else {
      throw AgentFailure(message: "MCP 响应缺少结果。")
    }
    return result
  }
  static func reply(to request: JSONValue) -> JSONValue {
    if request["method"].text == "ping" {
      return .object(["jsonrpc": .string("2.0"), "id": request["id"], "result": .object([:])])
    }
    return .object(["jsonrpc": .string("2.0"), "id": request["id"],
      "error": .object(["code": .number(-32601), "message": .string("Client method not supported")])])
  }
}
