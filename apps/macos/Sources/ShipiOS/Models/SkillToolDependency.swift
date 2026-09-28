import Foundation

struct SkillToolDependency: Decodable, Equatable {
  struct OAuth: Decodable, Equatable { var callbackPort: UInt16? }
  let type: String
  let value: String
  var description: String?
  var transport: String?
  var command: String?
  var url: String?
  var oauth: OAuth?

  func serverConfiguration(allowOAuthDeclaration: Bool = false) throws -> MCPServerConfiguration {
    guard type.caseInsensitiveCompare("mcp") == .orderedSame else {
      throw AgentFailure(message: "暂不支持此工具依赖类型：\(type)。")
    }
    guard oauth == nil || allowOAuthDeclaration else { throw AgentFailure(message: "此依赖需要 OAuth，当前独立 MCP 连接尚未支持。") }
    var server = MCPServerConfiguration()
    server.name = value
    switch (transport ?? "streamable_http").lowercased() {
    case "streamable_http": server.transport = .streamableHTTP; server.url = url ?? ""
    case "stdio": server.transport = .stdio; server.command = command ?? ""
    default: throw AgentFailure(message: "暂不支持此 MCP 传输类型：\(transport ?? "")。")
    }
    return try server.validated()
  }

  func resolve(in servers: [MCPServerConfiguration]) -> SkillDependencyResolution {
    do {
      let proposed = try serverConfiguration(allowOAuthDeclaration: true)
      if let existing = servers.first(where: { $0.skillDependencyKey == proposed.skillDependencyKey }) {
        return .configured(existing)
      }
      guard oauth == nil else { throw AgentFailure(message: "此依赖需要 OAuth，当前独立 MCP 连接尚未支持。") }
      if servers.contains(where: { $0.name.caseInsensitiveCompare(proposed.name) == .orderedSame }) {
        return .unavailable("已有同名 MCP 配置，但地址或启动命令不同；请在 MCP 设置中检查。")
      }
      return .missing(proposed)
    } catch { return .unavailable(error.localizedDescription) }
  }
}

enum SkillDependencyResolution {
  case configured(MCPServerConfiguration), missing(MCPServerConfiguration), unavailable(String)
}

extension MCPServerConfiguration {
  var skillDependencyKey: String {
    let endpoint = transport == .stdio ? command : url
    return transport.rawValue + ":" + endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
