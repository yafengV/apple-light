import Foundation

/// The current Codex confirmation offers these two methods, even on rebase-capable repositories.
enum GitHubPRMergeMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case merge, squash
  var id: String { rawValue }
  var label: String { self == .merge ? "合并提交" : "压缩合并" }
  var confirmationLabel: String { self == .merge ? "创建合并提交" : "压缩并合并" }
  var cliFlag: String { "--" + rawValue }
}

struct GitHubPRMergeSnapshot: Equatable, Sendable {
  let details: GitHubPRDetails
  let repository: GitHubRepository
  let isAuthor: Bool
  let allowedMethods: [GitHubPRMergeMethod]
  let isAutoMergeEnabled: Bool

  var headRevision: String? {
    guard let value = details.headRefOid, [40, 64].contains(value.count),
      value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return value
  }

  var showsActions: Bool { isAuthor && details.state.uppercased() != "MERGED" }

  var mergeDisabledReason: String? {
    if !isAuthor { return "只有 PR 作者可使用此入口。" }
    if details.state.uppercased() == "MERGED" { return "此 PR 已合并。" }
    if details.state.uppercased() == "CLOSED" { return "请先重新打开此 PR。" }
    if details.isDraft { return "请先将草稿标记为可供审查。" }
    if details.mergeable?.uppercased() == "CONFLICTING" { return "请先解决合并冲突。" }
    if details.mergeable?.uppercased() != "MERGEABLE" { return "GitHub 仍在检查是否可以合并。" }
    if details.checkSummary.failed > 0 { return "请先修复失败的检查。" }
    if details.checkSummary.pending > 0 { return "请等待检查完成。" }
    guard ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(details.mergeStateStatus?.uppercased() ?? ""),
      headRevision != nil, !allowedMethods.isEmpty else { return "此 PR 暂时无法合并。" }
    return nil
  }

  var autoMergeDisabledReason: String? {
    if !isAuthor { return "只有 PR 作者可使用此入口。" }
    if details.state.uppercased() != "OPEN" { return "请先打开此 PR。" }
    if !isAutoMergeEnabled && details.isDraft { return "请先将草稿标记为可供审查。" }
    if !isAutoMergeEnabled && (headRevision == nil || allowedMethods.isEmpty) { return "请先刷新 PR 状态。" }
    return nil
  }

  func method(preferred: GitHubPRMergeMethod) -> GitHubPRMergeMethod {
    allowedMethods.contains(preferred) ? preferred : allowedMethods.first ?? preferred
  }
}

enum GitHubPRMergeAction: Equatable, Sendable {
  case merge(GitHubPRMergeMethod)
  case autoMerge(enabled: Bool, method: GitHubPRMergeMethod)

  var method: GitHubPRMergeMethod {
    switch self { case .merge(let method), .autoMerge(_, let method): method }
  }
  var progressLabel: String {
    switch self {
    case .merge: "正在合并…"
    case .autoMerge(true, _): "正在启用自动合并…"
    case .autoMerge(false, _): "正在停用自动合并…"
    }
  }
  var usesMergeMethod: Bool {
    if case .autoMerge(false, _) = self { return false }
    return true
  }
  func isConfirmed(by snapshot: GitHubPRMergeSnapshot) -> Bool {
    switch self {
    case .merge: snapshot.details.state.uppercased() == "MERGED"
    case .autoMerge(true, _): snapshot.isAutoMergeEnabled || snapshot.details.state.uppercased() == "MERGED"
    case .autoMerge(false, _): !snapshot.isAutoMergeEnabled
    }
  }
}

struct GitHubPRMergeResult: Sendable {
  let snapshot: GitHubPRMergeSnapshot
  let notice: String?
}

struct GitHubPRMergeFailure: LocalizedError {
  let message: String
  let snapshot: GitHubPRMergeSnapshot?
  var errorDescription: String? { message }
}
