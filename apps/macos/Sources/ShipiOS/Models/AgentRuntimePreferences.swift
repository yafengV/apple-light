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
