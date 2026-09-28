import Foundation

enum GitHubPRCheckStatus: String, Codable, CaseIterable, Sendable {
  case failing, pending, neutral, skipped, unknown, passing

  static func checkRun(status: String?, conclusion: String?) -> Self {
    guard status?.lowercased() == "completed" else { return .pending }
    return conclusion.map(completed) ?? .unknown
  }
  static func completed(_ value: String) -> Self {
    switch value.uppercased() {
    case "SUCCESS", "SUCCESSFUL": .passing
    case "FAILURE", "FAILED", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED", "STARTUP_FAILURE": .failing
    case "EXPECTED", "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": .pending
    case "NEUTRAL": .neutral
    case "SKIPPED": .skipped
    default: .unknown
    }
  }
  var label: String {
    switch self {
    case .failing: "失败"
    case .pending: "进行中"
    case .neutral: "中立"
    case .skipped: "已跳过"
    case .unknown: "未知"
    case .passing: "通过"
    }
  }
  var icon: String {
    switch self {
    case .failing: "xmark.circle"
    case .pending: "circle.lefthalf.filled"
    case .passing: "checkmark.circle"
    case .neutral, .skipped, .unknown: "minus.circle"
    }
  }
  var order: Int { Self.allCases.firstIndex(of: self)! }
}

struct GitHubPRCheck: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let status: GitHubPRCheckStatus
  let link: String?
  let description: String?

  var validatedLink: URL? { Self.webLink(link) }

  static func webLink(_ link: String?) -> URL? {
    guard let link, let components = URLComponents(string: link),
      ["http", "https"].contains(components.scheme?.lowercased()),
      let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
    return components.url
  }
}

struct GitHubPRChecksRequest: Equatable, Sendable {
  let taskID: String
  let root: URL
  let pullRequest: GitHubPullRequest
  let headRevision: String
}

struct GitHubPRChecksSnapshot: Equatable, Sendable {
  let headRevision: String
  let checks: [GitHubPRCheck]
  let complete: Bool
  var pullRequestState: String? = nil
  var hasReportedFailure = false
  var hasReportedPending = false

  var sortedChecks: [GitHubPRCheck] {
    checks.enumerated().sorted {
      $0.element.status.order == $1.element.status.order ? $0.offset < $1.offset
        : $0.element.status.order < $1.element.status.order
    }.map(\.element)
  }
  var hasPendingChecks: Bool {
    !complete || hasReportedPending || checks.contains { $0.status == .pending || $0.status == .unknown }
  }
  var refreshSeconds: Int? {
    guard (pullRequestState ?? "OPEN").uppercased() == "OPEN" else { return nil }
    return hasPendingChecks ? 15 : 60
  }
  var statusLabel: String {
    if hasReportedFailure || checks.contains(where: { $0.status == .failing }) { return "检查失败" }
    if hasPendingChecks { return "检查进行中" }
    if checks.isEmpty { return "没有 CI 检查" }
    return "检查成功"
  }
  var notice: String? { complete ? nil : "部分检查详情未能读取。" }
}
