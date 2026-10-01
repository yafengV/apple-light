import Foundation

struct CodexWebSource: Codable, Equatable, Identifiable, Sendable {
  let title: String
  let url: String
  var id: String { url }

  static func completed(_ event: JSONValue) -> [Self] {
    guard event["type"].text == "web_search_end" else { return [] }
    var sources: [Self] = []
    var seen = Set<String>()
    func append(_ raw: String?, title: String?) {
      guard let raw, raw.utf8.count <= 4096,
        raw.hasPrefix("https://") || raw.hasPrefix("http://"),
        let url = try? BrowserAddress.url(raw),
        seen.insert(url.absoluteString).inserted else { return }
      let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      sources.append(Self(title: heading.isEmpty ? (url.host ?? url.absoluteString) : String(heading.prefix(160)),
        url: url.absoluteString))
    }
    for result in event["results"].items.prefix(100) {
      append(result["url"].text, title: result["title"].text)
    }
    if event["action"]["type"].text == "open_page" {
      append(event["action"]["url"].text, title: nil)
    }
    return sources
  }
}

struct CodexWebSearchActivity: Codable, Equatable, Sendable {
  let queryCount: Int
  let queries: [String]
  let viewedLinks: [CodexWebSource]

  static func completed(_ event: JSONValue) -> Self? {
    guard event["type"].text == "web_search_end" else { return nil }
    let action = event["action"]
    let kind = action["type"].text
    if kind == "open_page" || kind == "find_in_page" {
      guard let raw = action["url"].text, raw.utf8.count <= 4_096,
        raw.hasPrefix("https://") || raw.hasPrefix("http://"),
        let url = try? BrowserAddress.url(raw) else {
        return Self(queryCount: 0, queries: [], viewedLinks: [])
      }
      let source = CodexWebSource.completed(event).first { $0.url == url.absoluteString }
        ?? CodexWebSource(title: url.host ?? url.absoluteString, url: url.absoluteString)
      return Self(queryCount: 0, queries: [], viewedLinks: [source])
    }
    guard kind == nil || kind == "search" else {
      return Self(queryCount: 0, queries: [], viewedLinks: [])
    }
    let actionQueries = action["queries"].items.compactMap(\.text)
    let rawQueries = kind == "search"
      ? (actionQueries.isEmpty
        ? [action["query"].text ?? event["query"].text ?? ""]
        : actionQueries)
      : [event["query"].text ?? ""]
    let queries = rawQueries.compactMap { raw -> String? in
      let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return query.isEmpty ? nil : String(query.prefix(4_096))
    }
    return Self(queryCount: queries.count, queries: Array(queries.prefix(100)), viewedLinks: [])
  }

  static func legacy(_ execution: MCPToolExecution) -> Self {
    let parts = execution.arguments.split(separator: "：", maxSplits: 1)
    guard parts.count == 2 else {
      return Self(queryCount: 0, queries: [], viewedLinks: [])
    }
    let prefix = parts[0]
    let detail = String(parts[1])
    if prefix == "搜索" {
      let queries = detail.split(separator: "、").compactMap { value -> String? in
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
      }
      return Self(queryCount: queries.count, queries: queries, viewedLinks: [])
    }
    if prefix == "打开网页" || prefix == "页内查找" {
      let raw = prefix == "页内查找" ? String(detail.split(separator: "\n").last ?? "") : detail
      if let url = try? BrowserAddress.url(raw),
        raw.hasPrefix("https://") || raw.hasPrefix("http://") {
        return Self(queryCount: 0, queries: [], viewedLinks: [
          CodexWebSource(title: url.host ?? url.absoluteString, url: url.absoluteString),
        ])
      }
    }
    return Self(queryCount: 0, queries: [], viewedLinks: [])
  }
}

extension AgentRun {
  var codexWebSources: [CodexWebSource] {
    (try? result?["codex_web_sources"].decode([CodexWebSource].self)) ?? []
  }
}
