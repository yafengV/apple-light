import Foundation

struct SSHHost: Identifiable, Equatable, Sendable {
  var id: String { alias }
  let alias: String
  var hostName: String?
  var user: String?
  var port: Int?
  var identityFiles: [String] = []
  var status: String?

  var destination: String {
    let host = hostName ?? alias
    return user.map { "\($0)@\(host)" } ?? host
  }
}

enum SSHConfigParser {
  static func aliases(in text: String) -> [String] {
    var result: [String] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#") else { continue }
      let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard parts.first?.lowercased() == "host" else { continue }
      for alias in parts.dropFirst() where !alias.hasPrefix("!") && !alias.hasPrefix("-")
        && !alias.contains("*") && !alias.contains("?")
      {
        if !result.contains(alias) { result.append(alias) }
      }
    }
    return result
  }

  static func resolved(alias: String, output: String) -> SSHHost {
    var host = SSHHost(alias: alias)
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let parts = rawLine.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      switch parts[0].lowercased() {
      case "hostname": host.hostName = parts[1]
      case "user": host.user = parts[1]
      case "port": host.port = Int(parts[1])
      case "identityfile": host.identityFiles.append(parts[1])
      default: break
      }
    }
    return host
  }
}

enum SSHHostCatalog {
  static func load(configURL: URL) throws -> [SSHHost] {
    guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }
    let data = try Data(contentsOf: configURL, options: .mappedIfSafe)
    guard data.count <= 2_097_152, let text = String(data: data, encoding: .utf8) else {
      throw AgentFailure(message: "SSH 配置过大或不是 UTF-8。")
    }
    return SSHConfigParser.aliases(in: text).map { SSHHost(alias: $0) }
  }
}
