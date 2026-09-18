import Foundation

enum MCPTransport: String, Codable, CaseIterable {
  case stdio, streamableHTTP
  var title: String { self == .stdio ? "STDIO" : "Streamable HTTP" }
}

enum MCPServerEditState: Equatable {
  case unchanged, ready, invalid(String)
  var canSave: Bool { self == .ready }
  var validationMessage: String? {
    if case .invalid(let message) = self { return message }
    return nil
  }
}

struct MCPKeyValue: Codable, Equatable, Identifiable {
  var id = UUID()
  var key = ""
  var value = ""
}

struct MCPServerConfiguration: Codable, Equatable, Identifiable {
  var id = UUID()
  var name = ""
  var enabled = true
  var transport = MCPTransport.stdio
  var command = ""
  var arguments: [String] = []
  var environment: [MCPKeyValue] = []
  var environmentPassthrough: [String] = []
  var workingDirectory = ""
  var url = ""
  var bearerTokenEnvironmentVariable = ""
  var headers: [MCPKeyValue] = []
  var environmentHeaders: [MCPKeyValue] = []

  /// Compare what the connection uses, not transient row identities or fields
  /// belonging to an inactive transport. Call after validating both configs.
  func isEquivalent(to other: Self) -> Bool {
    guard id == other.id, name == other.name, enabled == other.enabled, transport == other.transport else { return false }
    func pairs(_ entries: [MCPKeyValue], headers: Bool = false) -> [String: String] {
      entries.reduce(into: [:]) { result, entry in
        result[headers ? entry.key.lowercased() : entry.key] = entry.value
      }
    }
    switch transport {
    case .stdio:
      return command == other.command && arguments == other.arguments
        && pairs(environment) == pairs(other.environment)
        && Set(environmentPassthrough) == Set(other.environmentPassthrough)
        && workingDirectory == other.workingDirectory
    case .streamableHTTP:
      return url == other.url && bearerTokenEnvironmentVariable == other.bearerTokenEnvironmentVariable
        && pairs(headers, headers: true) == pairs(other.headers, headers: true)
        && pairs(environmentHeaders, headers: true) == pairs(other.environmentHeaders, headers: true)
    }
  }

  func validated() throws -> Self {
    var result = self
    result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
      throw AgentFailure(message: "名称须为 1–64 位字母、数字、点、下划线或连字符，并以字母或数字开头。")
    }
    func envName(_ value: String) -> Bool {
      value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }
    func headerName(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.allSatisfy { byte in
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
      }
    }
    func pairs(_ entries: [MCPKeyValue], headers: Bool, environmentValues: Bool = false) throws {
      guard entries.count <= 100 else { throw AgentFailure(message: "每组最多添加 100 项。") }
      var seen = Set<String>()
      for entry in entries {
        guard headers ? headerName(entry.key) : envName(entry.key),
          seen.insert(headers ? entry.key.lowercased() : entry.key).inserted,
          !entry.value.utf8.contains(0), !headers || !entry.value.utf8.contains(where: { $0 == 13 || $0 == 10 }),
          !environmentValues || envName(entry.value) else {
          throw AgentFailure(message: "变量或请求头名称无效、重复，或值包含不支持的字符。")
        }
      }
    }
    if transport == .stdio {
      result.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !result.command.isEmpty, !result.command.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
        throw AgentFailure(message: "请填写有效的启动命令。")
      }
      guard arguments.count <= 100, arguments.allSatisfy({ !$0.contains("\0") }),
        environmentPassthrough.count <= 100, environmentPassthrough.allSatisfy(envName),
        Set(environmentPassthrough).count == environmentPassthrough.count,
        !workingDirectory.contains("\0") else {
        throw AgentFailure(message: "参数、环境变量透传或工作目录无效。")
      }
      try pairs(environment, headers: false)
    } else {
      result.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let components = URLComponents(string: result.url),
        ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
        let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
        components.fragment == nil else { throw AgentFailure(message: "请填写不含用户名、密码或片段的 HTTP(S) URL。") }
      guard bearerTokenEnvironmentVariable.isEmpty || envName(bearerTokenEnvironmentVariable) else {
        throw AgentFailure(message: "Bearer token 字段应填写环境变量名称。")
      }
      try pairs(headers, headers: true)
      try pairs(environmentHeaders, headers: true, environmentValues: true)
      let literal = Set(headers.map { $0.key.lowercased() })
      guard literal.isDisjoint(with: environmentHeaders.map { $0.key.lowercased() }),
        bearerTokenEnvironmentVariable.isEmpty
          || !literal.union(environmentHeaders.map { $0.key.lowercased() }).contains("authorization") else {
        throw AgentFailure(message: "同一请求头只能设置一次；Bearer token 不能同时设置 Authorization 请求头。")
      }
    }
    guard try JSONEncoder().encode(result).count <= 65_536 else { throw AgentFailure(message: "单个 MCP 配置不能超过 64 KiB。") }
    return result
  }
}

enum MCPServerStorage {
  static func load(root: URL) throws -> [MCPServerConfiguration] {
    let file = root.appendingPathComponent("mcp-servers.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let data = try Data(contentsOf: file)
    guard data.count <= 1_048_576 else { throw AgentFailure(message: "MCP 配置文件过大。") }
    let servers = try JSONDecoder().decode([MCPServerConfiguration].self, from: data)
    try validate(servers)
    return servers
  }

  static func save(_ servers: [MCPServerConfiguration], root: URL) throws {
    try validate(servers)
    let data = try JSONEncoder().encode(servers)
    guard data.count <= 1_048_576 else { throw AgentFailure(message: "全部 MCP 配置不能超过 1 MiB。") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("mcp-servers.json")
    if FileManager.default.fileExists(atPath: destination.path) {
      let properties = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
        throw AgentFailure(message: "MCP 配置路径不是普通文件，未覆盖现有内容。")
      }
    }
    let staging = root.appendingPathComponent(".mcp-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw AgentFailure(message: "无法保存 MCP 配置。")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    } else { try FileManager.default.moveItem(at: staging, to: destination) }
  }

  private static func validate(_ servers: [MCPServerConfiguration]) throws {
    guard servers.count <= 100, Set(servers.map(\.id)).count == servers.count,
      Set(servers.map { $0.name.lowercased() }).count == servers.count else {
      throw AgentFailure(message: "MCP 配置名称或标识重复，或超过 100 个服务器。")
    }
    for server in servers { _ = try server.validated() }
  }
}
