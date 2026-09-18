import Foundation

enum BrowserAccessDecision: String, Codable, CaseIterable, Identifiable {
  case ask, allow, block
  var id: String { rawValue }
  var title: String {
    switch self {
    case .ask: "每次询问"
    case .allow: "允许"
    case .block: "阻止"
    }
  }
}

struct BrowserPermissionPreferences: Codable, Equatable {
  var defaultDecision = BrowserAccessDecision.ask
  var sites: [String: BrowserAccessDecision] = [:]

  func decision(for url: URL) -> BrowserAccessDecision {
    guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      !host.isEmpty
    else { return .block }
    return sites[host] ?? defaultDecision
  }

  static func normalizedHost(_ input: String) throws -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw AgentFailure(message: "请输入网站域名。") }
    let candidate = value.contains("://") ? value : "https://\(value)"
    guard let parts = URLComponents(string: candidate),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      let rawHost = parts.host, parts.user == nil, parts.password == nil
    else { throw AgentFailure(message: "请输入有效的网站域名或 http/https 网址。") }
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
      throw AgentFailure(message: "请输入有效的网站域名。")
    }
    return host
  }
}
