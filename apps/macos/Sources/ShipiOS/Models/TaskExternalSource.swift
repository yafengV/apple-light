import Foundation
import Markdown

enum TaskExternalSourceActivity: String, Codable, Equatable, Hashable {
  case provided, read, created, updated

  var order: Int {
    switch self {
    case .provided: 0
    case .read: 1
    case .created: 2
    case .updated: 3
    }
  }

  var label: String {
    switch self {
    case .provided: "在会话中提供"
    case .read: "聊天期间读取"
    case .created: "聊天期间创建"
    case .updated: "聊天期间更新"
    }
  }
}

struct TaskExternalSource: Identifiable, Equatable {
  var resource: CodexWebSource
  var activities: [TaskExternalSourceActivity]
  var stableKey: String? = nil

  var id: String { stableKey ?? CodexWebSource.sourceKey(resource.url) ?? resource.url }
  var title: String { resource.title }
  var url: String { resource.url }

}

enum TaskProvidedWebLinks {
  static func collect(_ text: String) -> [CodexWebSource] {
    guard text.contains("http://") || text.contains("https://") else { return [] }
    var sources: [CodexWebSource] = []
    var seen = Set<String>()
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    func append(_ raw: String, label: String?) {
      guard raw.utf8.count <= 4_096,
        raw.hasPrefix("https://") || raw.hasPrefix("http://"),
        let url = try? BrowserAddress.url(raw),
        let key = CodexWebSource.sourceKey(url.absoluteString),
        seen.insert(key).inserted else { return }
      let heading = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      sources.append(CodexWebSource(
        title: heading.isEmpty || heading == raw ? (url.host ?? url.absoluteString)
          : String(heading.prefix(160)), url: url.absoluteString))
    }
    func plain(_ markup: any Markup) -> String {
      if let node = markup as? Markdown.Text { return node.string }
      if let node = markup as? InlineCode { return node.code }
      return markup.children.map(plain).joined()
    }
    func visit(_ markup: any Markup) {
      if let link = markup as? Markdown.Link, let destination = link.destination {
        append(destination, label: plain(link))
        return
      }
      if markup is CodeBlock || markup is InlineCode || markup is HTMLBlock { return }
      if let node = markup as? Markdown.Text {
        let value = node.string
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in detector?.matches(in: value, range: range) ?? [] {
          if let url = match.url { append(url.absoluteString, label: nil) }
        }
        return
      }
      for child in markup.children { visit(child) }
    }
    visit(Document(parsing: text))
    return sources
  }
}
