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

/// A saved definition is copied into each task's permission snapshot so editing
/// or deleting the catalog entry cannot silently change an existing task.
struct AgentNamedPermissionProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
  var id: String
  var description: String
  var configTOML: String
  /// Derived by the bundled Core validator. Old records without this field
  /// require the confirmed full-access toggle until validated again.
  var requiresFullAccess: Bool

  init(id: String, description: String, configTOML: String,
    requiresFullAccess: Bool = false) {
    self.id = id
    self.description = description
    self.configTOML = configTOML
    self.requiresFullAccess = requiresFullAccess
  }

  private enum CodingKeys: String, CodingKey {
    case id, description, configTOML, requiresFullAccess
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    description = try values.decode(String.self, forKey: .description)
    configTOML = try values.decode(String.self, forKey: .configTOML)
    requiresFullAccess = try values.decodeIfPresent(Bool.self,
      forKey: .requiresFullAccess) ?? true
  }

  var title: String { description.isEmpty ? id : "\(id) · \(description)" }

  var hasValidShape: Bool {
    !id.isEmpty && id.utf8.count <= 64
      && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
        || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 }
      && description.utf8.count <= 160 && configTOML.utf8.count <= 64 * 1024
  }
}

struct AgentRuntimePreferences: Codable, Equatable, Hashable {
  var approvalPolicy = AgentApprovalPolicy.onRequest
  var approvalReviewer = AgentApprovalReviewer.user
  var sandboxMode = AgentSandboxMode.workspaceWrite
  var networkAccess = false
  var namedProfile: AgentNamedPermissionProfile?

  static let askForApproval = AgentRuntimePreferences()
  static let approveForMe = AgentRuntimePreferences(approvalReviewer: .autoReview)
  static let fullAccess = AgentRuntimePreferences(approvalPolicy: .never,
    sandboxMode: .fullAccess)

  init(approvalPolicy: AgentApprovalPolicy = .onRequest,
    approvalReviewer: AgentApprovalReviewer = .user,
    sandboxMode: AgentSandboxMode = .workspaceWrite,
    networkAccess: Bool = false, namedProfile: AgentNamedPermissionProfile? = nil) {
    self.approvalPolicy = approvalPolicy
    self.approvalReviewer = approvalReviewer
    self.sandboxMode = sandboxMode
    self.networkAccess = networkAccess
    self.namedProfile = namedProfile
  }

  private enum CodingKeys: String, CodingKey {
    case approvalPolicy, approvalReviewer, sandboxMode, networkAccess, namedProfile
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    approvalPolicy = try values.decode(AgentApprovalPolicy.self, forKey: .approvalPolicy)
    approvalReviewer = try values.decodeIfPresent(AgentApprovalReviewer.self,
      forKey: .approvalReviewer) ?? .user
    sandboxMode = try values.decode(AgentSandboxMode.self, forKey: .sandboxMode)
    networkAccess = try values.decode(Bool.self, forKey: .networkAccess)
    namedProfile = try values.decodeIfPresent(AgentNamedPermissionProfile.self, forKey: .namedProfile)
  }

  var isFullAccessPreset: Bool {
    namedProfile == nil && sandboxMode == .fullAccess && approvalPolicy == .never
  }

  var menuTitle: String {
    if let namedProfile { return namedProfile.id }
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
