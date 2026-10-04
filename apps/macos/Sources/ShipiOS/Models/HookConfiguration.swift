import Foundation

struct HookDecision: Codable, Equatable, Sendable {
  var enabled: Bool?
  var trustedHash: String?
  enum CodingKeys: String, CodingKey { case enabled; case trustedHash = "trusted_hash" }
}

struct HookSourceBinding: Codable, Equatable, Sendable {
  let id: String
  let configuration: String
  var states: [String: HookDecision] = [:]
  var plugin: HookPluginBinding? = nil
}

struct HookPluginBinding: Codable, Equatable, Sendable {
  let id: String
  let fingerprint: String
}

struct HookMetadata: Codable, Equatable, Identifiable, Sendable {
  let sourceId: String
  let key: String
  let eventName: String
  let handler: JSONValue
  let definition: JSONValue
  let matcher: String?
  let timeoutSec: UInt64
  let statusMessage: String?
  let additionalContextLimit: Int?
  let enabled: Bool
  let currentHash: String
  let trustStatus: String
  var source: String? = nil
  var pluginId: String? = nil
  var id: String { sourceId + ":" + key }
  var needsReview: Bool { trustStatus == "untrusted" || trustStatus == "modified" }
  var managed: Bool { trustStatus == "managed" }
  var active: Bool { managed || (enabled && trustStatus == "trusted") }
  var eventTitle: String { Self.events.first { $0.0 == eventName }?.1 ?? eventName }
  var eventDescription: String {
    switch eventName {
    case "pre_tool_use": "工具执行前"
    case "permission_request": "请求操作权限时"
    case "post_tool_use": "工具执行后"
    case "pre_compact": "整理会话上下文前"
    case "post_compact": "整理会话上下文后"
    case "session_start": "开始会话时"
    case "session_end": "结束会话时"
    case "user_prompt_submit": "提交用户输入时"
    case "subagent_start": "子 Agent 启动时"
    case "subagent_stop": "子 Agent 停止时"
    case "stop": "模型结束当前回合前"
    case "interrupt": "当前回合被中断时"
    default: ""
    }
  }
  func title(index: Int) -> String {
    let message = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return message.isEmpty ? "Hook \(index + 1)" : "\(index + 1) - \(message)"
  }
  static let events: [(String, String)] = [
    ("session_start", "SessionStart"), ("user_prompt_submit", "UserPromptSubmit"),
    ("pre_tool_use", "PreToolUse"), ("permission_request", "PermissionRequest"),
    ("post_tool_use", "PostToolUse"), ("pre_compact", "PreCompact"),
    ("post_compact", "PostCompact"), ("subagent_start", "SubagentStart"),
    ("subagent_stop", "SubagentStop"), ("stop", "Stop"),
    ("interrupt", "Interrupt"), ("session_end", "SessionEnd")]
}

struct HookInventory: Decodable, Sendable {
  let hooks: [HookMetadata]
  let warnings: [String]
}

struct HookSettingsSource: Identifiable, Equatable, Sendable {
  let id: String
  let pluginID: String
  let name: String
  let label: String
  let fileURL: URL
  let pluginEnabled: Bool
  var binding: HookSourceBinding
  var hooks: [HookMetadata] = []
  var warnings: [String] = []
  var error: String?
  var reviewCount: Int { hooks.filter(\.needsReview).count }
  var activeCount: Int { pluginEnabled ? hooks.filter(\.active).count : 0 }
  var eventNames: [String] {
    var seen: Set<String> = []
    return hooks.compactMap { seen.insert($0.eventName).inserted ? $0.eventName : nil }
  }
}

struct HookSettingsGroup: Identifiable, Equatable {
  let id: String
  let sources: [HookSettingsSource]
  var name: String { sources.first?.name ?? "Hooks" }
  var label: String { sources.count == 1 ? sources[0].label : "\(sources.count) 个配置文件" }
  var pluginEnabled: Bool { sources.first?.pluginEnabled == true }
  var hooks: [HookMetadata] { sources.flatMap(\.hooks) }
  var warnings: [String] { sources.flatMap { source in source.warnings + (source.error.map { [source.label + ": " + $0] } ?? []) } }
  var reviewCount: Int { hooks.filter(\.needsReview).count }
  var activeCount: Int { sources.reduce(0) { $0 + $1.activeCount } }
  var eventNames: [String] {
    var seen: Set<String> = []
    return hooks.compactMap { seen.insert($0.eventName).inserted ? $0.eventName : nil }
  }
}
