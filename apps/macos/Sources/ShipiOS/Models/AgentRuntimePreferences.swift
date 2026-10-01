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

enum AgentApprovalReviewer: String, Codable, CaseIterable {
  case user
  case autoReview = "auto_review"

  var title: String {
    switch self {
    case .user: "由我审批"
    case .autoReview: "自动审查批准"
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

  static func visibleOptions(showFullAccess: Bool) -> [AgentSandboxMode] {
    allCases.filter { $0 != .fullAccess || showFullAccess }
  }
}

struct AgentRuntimePreferences: Codable, Equatable, Hashable {
  var approvalPolicy = AgentApprovalPolicy.onRequest
  var approvalReviewer = AgentApprovalReviewer.user
  var sandboxMode = AgentSandboxMode.workspaceWrite
  var networkAccess = false

  static let askForApproval = AgentRuntimePreferences()
  static let approveForMe = AgentRuntimePreferences(approvalReviewer: .autoReview)
  static let fullAccess = AgentRuntimePreferences(approvalPolicy: .never,
    sandboxMode: .fullAccess)

  init(approvalPolicy: AgentApprovalPolicy = .onRequest,
    approvalReviewer: AgentApprovalReviewer = .user,
    sandboxMode: AgentSandboxMode = .workspaceWrite,
    networkAccess: Bool = false) {
    self.approvalPolicy = approvalPolicy
    self.approvalReviewer = approvalReviewer
    self.sandboxMode = sandboxMode
    self.networkAccess = networkAccess
  }

  private enum CodingKeys: String, CodingKey {
    case approvalPolicy, approvalReviewer, sandboxMode, networkAccess
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    approvalPolicy = try values.decode(AgentApprovalPolicy.self, forKey: .approvalPolicy)
    approvalReviewer = try values.decodeIfPresent(AgentApprovalReviewer.self,
      forKey: .approvalReviewer) ?? .user
    sandboxMode = try values.decode(AgentSandboxMode.self, forKey: .sandboxMode)
    networkAccess = try values.decode(Bool.self, forKey: .networkAccess)
  }

  var isFullAccessPreset: Bool {
    sandboxMode == .fullAccess && approvalPolicy == .never
  }

  var menuTitle: String {
    if self == .askForApproval { return "按需请求批准" }
    if self == .approveForMe { return "自动审查批准" }
    if isFullAccessPreset { return "完全访问" }
    if sandboxMode == .readOnly && approvalPolicy == .onRequest { return "只读" }
    return "自定义权限"
  }
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
