import Foundation

enum ResponsePersonality: String, Codable, CaseIterable, Identifiable {
  case friendly, pragmatic, none
  var id: String { rawValue }
  var title: String {
    switch self {
    case .friendly: "友好"
    case .pragmatic: "务实"
    case .none: "无"
    }
  }
  var instruction: String {
    switch self {
    case .friendly: "使用温暖、友好、耐心的语气，清楚解释必要的背景，避免奉承。"
    case .pragmatic: "使用直接、务实的语气，先说结论，再提供必要的依据和具体下一步，避免冗长铺垫。"
    case .none: ""
    }
  }
}

struct Personalization: Codable, Equatable {
  var personality: ResponsePersonality = .none
  var showSuggestedPrompts = true
  static let baseInstructions =
    "你是 ShipiOS 中的开发助手。仅依据对话中明确提供的信息回答，不要声称执行了未执行的命令或修改了文件。"

  init(personality: ResponsePersonality = .none, showSuggestedPrompts: Bool = true) {
    self.personality = personality
    self.showSuggestedPrompts = showSuggestedPrompts
  }

  enum CodingKeys: String, CodingKey { case personality, showSuggestedPrompts }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    personality = try c.decodeIfPresent(ResponsePersonality.self, forKey: .personality) ?? .none
    showSuggestedPrompts = try c.decodeIfPresent(Bool.self, forKey: .showSuggestedPrompts) ?? true
  }

  func systemInstructions(custom: String) -> String {
    [Self.baseInstructions, personality.instruction, custom]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
  }
}

enum PersonalizationStorage {
  static let maximumInstructionBytes = 65_536

  static func load(root: URL, legacyInstructions: String) throws -> (Personalization, String) {
    let preferencesURL = root.appendingPathComponent("personalization.json")
    let instructionsURL = root.appendingPathComponent("AGENTS.md")
    let fm = FileManager.default
    let migrated = fm.fileExists(atPath: preferencesURL.path)
    let preferences = migrated
      ? try JSONDecoder().decode(Personalization.self, from: Data(contentsOf: preferencesURL))
      : Personalization()
    let instructions: String
    if fm.fileExists(atPath: instructionsURL.path) {
      let handle = try FileHandle(forReadingFrom: instructionsURL)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maximumInstructionBytes + 1) ?? Data()
      guard data.count <= maximumInstructionBytes, let text = String(data: data, encoding: .utf8) else {
        throw AgentFailure(message: "无法读取个人指令：AGENTS.md 须为 UTF-8 文本且不超过 64 KiB。")
      }
      instructions = text
    } else {
      instructions = migrated || legacyInstructions == Personalization.baseInstructions
        ? "" : legacyInstructions
      try saveInstructions(instructions, root: root)
    }
    if !migrated { try save(preferences, root: root) }
    return (preferences, instructions)
  }

  static func save(_ preferences: Personalization, root: URL) throws {
    try write(JSONEncoder().encode(preferences), name: "personalization.json", root: root)
  }

  static func saveInstructions(_ instructions: String, root: URL) throws {
    guard instructions.utf8.count <= maximumInstructionBytes else {
      throw AgentFailure(message: "自定义指令不能超过 64 KiB。")
    }
    try write(Data(instructions.utf8), name: "AGENTS.md", root: root)
  }

  private static func write(_ data: Data, name: String, root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
