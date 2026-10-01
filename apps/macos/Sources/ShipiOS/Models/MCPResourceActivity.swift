import Foundation

/// Codex's explicit MCP resource activity metadata; generic tool text is not a source.
struct MCPResourceActivity: Codable, Equatable {
  let id: String
  let source: CodexWebSource
  let mimeType: String?
  let activities: [TaskExternalSourceActivity]

  static func parse(_ result: JSONValue) -> [Self]? {
    guard result["isError"].boolean != true,
      case .object = result,
      case .object(let metadata) = result["_meta"]["openai/resourceActivities"] else { return nil }
    guard metadata["version"]?.int == 1,
      case .array(let entries) = metadata["resources"] ?? .null,
      entries.count <= 500 else { return nil }
    var resources: [Self] = []
    for entry in entries {
      guard let id = entry["id"].text?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
        let raw = entry["url"].text, raw.utf8.count <= 4_096,
        raw.hasPrefix("https://") || raw.hasPrefix("http://"),
        let url = try? BrowserAddress.url(raw),
        case .array(let values) = entry["activities"], !values.isEmpty else { return nil }
      var activities: [TaskExternalSourceActivity] = []
      for value in values {
        guard let name = value.text,
          let activity = TaskExternalSourceActivity(rawValue: name),
          activity != .provided else { return nil }
        if !activities.contains(activity) { activities.append(activity) }
      }
      activities.sort { $0.order < $1.order }
      let title = entry["title"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      resources.append(Self(id: String(id.prefix(256)), source: CodexWebSource(
        title: title.isEmpty ? (url.host ?? url.absoluteString) : String(title.prefix(160)),
        url: url.absoluteString),
        mimeType: entry["mimeType"].text.map { String($0.prefix(160)) },
        activities: activities))
    }
    return resources
  }

  static func restored(from output: String?) -> [Self]? {
    guard let output,
      let result = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) else { return nil }
    return parse(result)
  }
}
