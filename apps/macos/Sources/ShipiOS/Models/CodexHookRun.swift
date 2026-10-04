import Foundation

/// Core wire summaries stay separate from response items: Hooks have their own
/// completed-turn statistics, and context output belongs to the model input.
struct CodexHookRun: Codable, Equatable, Identifiable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let kind: String
    let text: String
    var label: String {
      switch kind {
      case "warning": "消息"
      case "feedback": "反馈"
      case "error": "错误"
      case "stop": "停止原因"
      default: "输出"
      }
    }
  }
  let hookID: String
  var invocationID: String? = nil
  var runtimeTurnID: String? = nil
  var scope: String? = nil
  var id: String { invocationID ?? hookID }
  let startedAt: Int
  let completedAt: Int?
  let eventName: String
  let source: String
  let status: String
  let statusMessage: String?
  let displayOrder: Int
  let entries: [Entry]
  enum CodingKeys: String, CodingKey {
    case invocationID, scope, source, status, entries
    case runtimeTurnID = "runtime_turn_id"
    case hookID = "id", startedAt = "started_at", completedAt = "completed_at"
    case eventName = "event_name", statusMessage = "status_message", displayOrder = "display_order"
  }
  var eventTitle: String { HookMetadata.events.first { $0.0 == eventName }?.1 ?? eventName }
  var sourceLabel: String {
    switch source {
    case "plugin": "插件"
    case "user": "用户"
    case "project": "项目"
    case "session_flags": "会话"
    case "system", "mdm", "cloud_requirements", "cloud_managed_config",
      "legacy_managed_config_file", "legacy_managed_config_mdm": "管理员"
    default: "未知"
    }
  }
  var statusLabel: String {
    switch status {
    case "completed": "已完成"
    case "blocked": "已阻止"
    case "failed": "失败"
    case "stopped": "已停止"
    default: "未知"
    }
  }
  var hasWarningStatus: Bool { status == "blocked" || status == "failed" }
  var visibleEntries: [Entry] { entries.filter { ["warning", "feedback", "error", "stop"].contains($0.kind) } }
  var visibleStatusMessage: String? {
    let text = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? nil : text
  }
  var fallbackMessage: String? {
    guard visibleEntries.isEmpty, status != "completed" else { return nil }
    switch status {
    case "blocked": return "此 Hook 未提供阻止原因。"
    case "failed": return "此 Hook 未提供错误详情。"
    default: return "此 Hook 未提供停止原因。"
    }
  }
}

struct CodexHookStats: Equatable {
  let runs: [CodexHookRun]
  init?(_ runs: [CodexHookRun]) {
    self.runs = runs.filter { $0.status != "running" }
    if self.runs.isEmpty { return nil }
  }
  var count: Int { runs.count }
  var blockedCount: Int { runs.filter { $0.status == "blocked" }.count }
  var errorCount: Int { runs.filter { $0.status == "failed" }.count }
  var hasWarnings: Bool { blockedCount > 0 || errorCount > 0 }
}

extension AgentRun {
  var codexHookRuns: [CodexHookRun] {
    guard let value = result?["codex_hook_runs"], let data = try? JSONEncoder().encode(value),
      let runs = try? JSONDecoder().decode([CodexHookRun].self, from: data) else { return [] }
    return runs
  }
  var codexHookStats: CodexHookStats? { isActive ? nil : CodexHookStats(codexHookRuns) }
}
