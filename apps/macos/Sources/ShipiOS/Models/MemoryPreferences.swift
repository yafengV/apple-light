import Foundation

struct SavedMemory: Codable, Equatable, Identifiable {
  let id: UUID
  var text: String
  let createdAt: Date
  var updatedAt: Date

  init(id: UUID = UUID(), text: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
    self.id = id
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct MemoryPreferences: Codable, Equatable {
  var enabled = true
  var items: [SavedMemory] = []

  init(enabled: Bool = true, items: [SavedMemory] = []) {
    self.enabled = enabled
    self.items = items
  }

  enum CodingKeys: String, CodingKey { case enabled, items }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    items = try container.decodeIfPresent([SavedMemory].self, forKey: .items) ?? []
  }

  var instructions: String {
    guard enabled, !items.isEmpty else { return "" }
    let list = items.map {
      "- " + $0.text.replacingOccurrences(of: "\n", with: "\n  ")
    }.joined(separator: "\n")
    return """
      以下是用户在 ShipiOS 中明确保存的长期记忆。仅在与当前请求相关时参考；若内容与当前请求冲突，以当前请求为准：
      \(list)
      """
  }
}

enum MemoryStorage {
  static let maximumItems = 100
  static let maximumItemBytes = 4_096
  static let maximumTotalBytes = 65_536

  static func load(root: URL) throws -> MemoryPreferences {
    let url = root.appendingPathComponent("memories.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return MemoryPreferences() }
    let preferences = try JSONDecoder().decode(MemoryPreferences.self, from: Data(contentsOf: url))
    try validate(preferences)
    return preferences
  }

  static func save(_ preferences: MemoryPreferences, root: URL) throws {
    try validate(preferences)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("memories.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(preferences).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func normalizedText(_ text: String) throws -> String {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw AgentFailure(message: "记忆内容不能为空。") }
    guard value.utf8.count <= maximumItemBytes else {
      throw AgentFailure(message: "单条记忆不能超过 4 KiB。")
    }
    return value
  }

  private static func validate(_ preferences: MemoryPreferences) throws {
    guard preferences.items.count <= maximumItems else {
      throw AgentFailure(message: "最多保存 \(maximumItems) 条记忆。")
    }
    guard Set(preferences.items.map(\.id)).count == preferences.items.count else {
      throw AgentFailure(message: "记忆数据包含重复标识。")
    }
    var total = 0
    for item in preferences.items {
      let normalized = try normalizedText(item.text)
      guard normalized == item.text else {
        throw AgentFailure(message: "记忆内容不能以空白开头或结尾。")
      }
      total += item.text.utf8.count
    }
    guard total <= maximumTotalBytes else {
      throw AgentFailure(message: "全部记忆内容不能超过 64 KiB。")
    }
  }
}
