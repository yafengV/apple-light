import Foundation

enum AgentApprovalPolicy: String, Codable, CaseIterable {
  case onRequest = "on-request"
  case never

  var title: String {
    switch self {
    case .onRequest: "按需请求批准"
    case .never: "永不请求批准"
    }
  }
}

enum AgentSandboxMode: String, Codable, CaseIterable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case fullAccess = "danger-full-access"

  var title: String {
    switch self {
    case .readOnly: "只读"
    case .workspaceWrite: "工作区写入"
    case .fullAccess: "完全访问"
    }
  }
}

struct AgentRuntimePreferences: Codable, Equatable {
  var approvalPolicy = AgentApprovalPolicy.onRequest
  var sandboxMode = AgentSandboxMode.workspaceWrite
  var networkAccess = false
}

enum AgentResponseVerbosity: String, Codable, CaseIterable {
  case modelDefault = "default"
  case low, medium, high

  var title: String {
    switch self {
    case .modelDefault: "模型默认"
    case .low: "简洁"
    case .medium: "适中"
    case .high: "详细"
    }
  }
}

enum AgentReasoningSummary: String, Codable, CaseIterable {
  case auto, concise, detailed, none

  var title: String {
    switch self {
    case .auto: "自动"
    case .concise: "简要"
    case .detailed: "详细"
    case .none: "关闭"
    }
  }
}

struct AgentResponsePreferences: Codable, Equatable {
  var verbosity = AgentResponseVerbosity.modelDefault
  var reasoningSummary = AgentReasoningSummary.auto
}

enum AgentWebSearchMode: String, Codable, CaseIterable {
  case disabled, cached, indexed, live

  var title: String {
    switch self {
    case .disabled: "关闭"
    case .cached: "缓存"
    case .indexed: "索引"
    case .live: "实时"
    }
  }
}

enum AgentAdvancedReasoningEffort: String, Codable, CaseIterable, Hashable {
  case max, ultra

  var title: String { rawValue == "max" ? "Max" : "Ultra" }
}

enum AgentReasoningEfforts {
  static let standard = ["", "none", "minimal", "low", "medium", "high", "xhigh"]
  static let titles = [
    "": "服务默认", "none": "无", "minimal": "最少", "low": "低", "medium": "中",
    "high": "高", "xhigh": "极高", "max": "Max", "ultra": "Ultra",
  ]

  static func available(advanced: Set<AgentAdvancedReasoningEffort>) -> [String] {
    standard + AgentAdvancedReasoningEffort.allCases.filter { advanced.contains($0) }.map(\.rawValue)
  }
}
