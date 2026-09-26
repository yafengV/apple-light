import Foundation

enum BrowserAddressInput {
  static func url(_ text: String) throws -> URL {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return try BrowserAddress.url(input) }
    if looksLikeAddress(input) { return try BrowserAddress.url(input) }
    var search = URLComponents(string: "https://www.google.com/search")!
    search.queryItems = [URLQueryItem(name: "q", value: input)]
    return search.url!
  }

  static func historyMatches(_ text: String, in history: [BrowserHistoryEntry], limit: Int = 6) -> [BrowserHistoryEntry] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, limit > 0 else { return [] }
    return Array(history.filter {
      $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)
    }.prefix(limit))
  }

  static func isSearchQuery(_ text: String) -> Bool {
    let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return !input.isEmpty && !looksLikeAddress(input)
  }

  private static func looksLikeAddress(_ input: String) -> Bool {
    if input.contains("://") { return true }
    if input.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return false }
    if input.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return true }
    let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
    return host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("127.")
      || host.hasPrefix("[::1]") || host.contains(".")
  }
}
