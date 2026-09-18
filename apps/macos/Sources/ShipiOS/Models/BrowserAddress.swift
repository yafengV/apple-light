import Foundation

enum BrowserAddress {
  static func url(_ text: String) throws -> URL {
    let entered = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !entered.isEmpty else { throw AgentFailure(message: "请输入网址。") }
    let raw: String
    if entered.contains("://") { raw = entered }
    else {
      if URLComponents(string: entered)?.scheme != nil,
        entered.range(of: "^[^/:]+:[0-9]+(?:/|\\?|#|$)", options: .regularExpression) == nil {
        throw AgentFailure(message: "请输入有效的 http 或 https 地址。")
      }
      let host = entered.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entered
      let local = host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.")
        || host == "[::1]" || host.hasPrefix("[::1]:")
      raw = (local ? "http://" : "https://") + entered
    }
    guard let parts = URLComponents(string: raw), let url = parts.url,
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      let host = parts.host, !host.isEmpty,
      host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      parts.user == nil, parts.password == nil,
      parts.port.map({ (1...65535).contains($0) }) ?? true else {
      throw AgentFailure(message: "请输入有效的 http 或 https 地址，不要在地址中包含登录凭据。")
    }
    return url
  }
  static func permits(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank"
  }
}
