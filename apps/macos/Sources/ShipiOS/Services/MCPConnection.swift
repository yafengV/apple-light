import Foundation

@MainActor final class MCPConnection {
  private let wire: any MCPWire
  private var nextID = 0
  private var supportsTools = false
  private(set) var serverName = ""
  var onDisconnect: ((String) -> Void)?
  var onToolsChanged: (() -> Void)?

  init(configuration: MCPServerConfiguration, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    if configuration.transport == .stdio {
      let wire = try MCPStdioWire(configuration: configuration, environment: environment)
      self.wire = wire
      wire.onDisconnect = { [weak self] in self?.onDisconnect?($0) }
      wire.onToolsChanged = { [weak self] in self?.onToolsChanged?() }
    } else { wire = try MCPHTTPWire(configuration: configuration, environment: environment) }
  }

  init(wire: any MCPWire) { self.wire = wire }

  func initialize() async throws -> [MCPToolDescription] {
    let result = try await request("initialize", params: [
      "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
      "clientInfo": .object(["name": .string("ShipiOS"), "version": .string("0.1.0")])])
    guard let version = result["protocolVersion"].text,
      ["2025-11-25", "2025-06-18", "2025-03-26"].contains(version),
      let name = result["serverInfo"]["name"].text else {
      throw AgentFailure(message: "MCP 初始化失败：协议版本或服务器信息无效。")
    }
    serverName = name
    wire.protocolVersion = version
    supportsTools = result["capabilities"]["tools"] != .null
    _ = try await wire.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
    return try await listTools()
  }

  func listTools() async throws -> [MCPToolDescription] {
    guard supportsTools else { return [] }
    var tools: [MCPToolDescription] = [], names = Set<String>(), cursors = Set<String>()
    var cursor: String?
    for _ in 0..<100 {
      let params: [String: JSONValue] = cursor.map { ["cursor": .string($0)] } ?? [:]
      let result = try await request("tools/list", params: params)
      guard case .array(let items) = result["tools"] else { throw AgentFailure(message: "MCP 工具列表无效。") }
      for item in items {
        guard let name = item["name"].text, !name.isEmpty, names.insert(name).inserted,
          case .object = item["inputSchema"], tools.count < 10_000 else {
          throw AgentFailure(message: "MCP 工具名称或参数定义无效，或列表过大。")
        }
        tools.append(MCPToolDescription(name: name, title: item["title"].text ?? name,
          summary: item["description"].text ?? "", inputSchema: item["inputSchema"]))
      }
      guard result["nextCursor"] != .null else { return tools }
      guard let next = result["nextCursor"].text, !next.isEmpty, cursors.insert(next).inserted else {
        throw AgentFailure(message: "MCP 工具列表分页游标无效。")
      }
      cursor = next
    }
    throw AgentFailure(message: "MCP 工具列表超过分页限制。")
  }

  private func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
    nextID += 1
    let id = JSONValue.number(Double(nextID))
    let response = try await withTaskCancellationHandler {
      try await wire.send(.object(["jsonrpc": .string("2.0"), "id": id,
        "method": .string(method), "params": .object(params)]))
    } onCancel: { [wire] in
      Task { @MainActor in
        _ = try? await wire.send(.object(["jsonrpc": .string("2.0"),
          "method": .string("notifications/cancelled"), "params": .object(["requestId": id])]))
      }
    }
    return try MCPMessages.result(response, id: id)
  }

  func close() async { await wire.close() }

  func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
    guard supportsTools, case .object = arguments else { throw AgentFailure(message: "MCP 工具参数无效。") }
    return try await request("tools/call", params: ["name": .string(name), "arguments": arguments])
  }
}
