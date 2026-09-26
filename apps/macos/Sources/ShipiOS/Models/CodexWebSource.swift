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

extension AgentRun {
  var codexWebSources: [CodexWebSource] {
    (try? result?["codex_web_sources"].decode([CodexWebSource].self)) ?? []
  }
}
