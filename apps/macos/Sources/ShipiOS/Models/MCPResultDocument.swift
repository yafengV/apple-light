import Foundation

struct MCPResultDocument: Equatable, Sendable {
  struct Block: Equatable, Identifiable, Sendable {
    let id: Int
    let content: Content
    let annotations: String?
  }
  enum Content: Equatable, Sendable {
    case text(String)
    case image(base64: String, mime: String)
    case audio(base64: String, mime: String)
    case resourceLink(title: String, uri: String, description: String?)
    case resource(uri: String, mime: String?, text: String?, blob: String?)
    case unknown(String)
  }
  let blocks: [Block]
  let structured: String?
  let isError: Bool

  static func parse(_ raw: String) -> Self {
    guard raw.utf8.count <= 16 * 1_048_576,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
      case .object = value, value["content"] != .null || value["structuredContent"] != .null else {
      return Self(blocks: [.init(id: 0, content: .text(raw), annotations: nil)], structured: nil, isError: false)
    }
    let structured = value["structuredContent"]
    let entries: [JSONValue]
    switch value["content"] {
    case .array(let items): entries = items
    case .null: entries = []
    default: entries = [value["content"]]
    }
    let blocks = entries.enumerated().compactMap { index, item -> Block? in
      let content: Content
      var annotations = item["annotations"]
      switch item["type"].text {
      case "text":
        guard let text = item["text"].text else { return unknown(item, index: index) }
        // MCP commonly includes the same structured result twice for old clients.
        if structured != .null, annotations == .null,
          (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) == structured { return nil }
        content = .text(text)
      case "image", "audio":
        guard let data = item["data"].text, let mime = item["mimeType"].text else { return unknown(item, index: index) }
        content = item["type"].text == "image" ? .image(base64: data, mime: mime) : .audio(base64: data, mime: mime)
      case "resource_link":
        guard let uri = item["uri"].text else { return unknown(item, index: index) }
        content = .resourceLink(title: item["title"].text ?? item["name"].text ?? uri,
          uri: uri, description: item["description"].text)
      case "resource", "embedded_resource":
        let resource = item["resource"]
        guard let uri = resource["uri"].text else { return unknown(item, index: index) }
        content = .resource(uri: uri, mime: resource["mimeType"].text,
          text: resource["text"].text, blob: resource["blob"].text)
        if resource["annotations"] != .null { annotations = resource["annotations"] }
      default: return unknown(item, index: index)
      }
      return Block(id: index, content: content, annotations: annotations == .null ? nil : annotations.pretty)
    }
    return Self(blocks: blocks, structured: structured == .null ? nil : structured.pretty,
      isError: value["isError"].boolean == true)
  }

  private static func unknown(_ value: JSONValue, index: Int) -> Block {
    Block(id: index, content: .unknown(value.pretty), annotations: nil)
  }
}
