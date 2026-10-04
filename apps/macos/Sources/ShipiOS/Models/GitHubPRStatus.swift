import Foundation

enum GitHubPRStatus: String, CaseIterable, Identifiable, Sendable {
  case draft, open, closed, merged
  var id: String { rawValue }
  static let options: [Self] = [.draft, .open, .closed]
  init(_ details: GitHubPRDetails) {
    switch details.state.uppercased() {
    case "MERGED": self = .merged
    case "CLOSED": self = .closed
    default: self = details.isDraft ? .draft : .open
    }
  }
  var label: String {
    switch self { case .draft: "草稿"; case .open: "可供审查"; case .closed: "已关闭"; case .merged: "已合并" }
  }
  func canSelect(from current: Self) -> Bool {
    current != .merged && self != .merged && self != current && !(self == .draft && current == .closed)
  }
  func confirmed(by snapshot: GitHubPRMergeSnapshot) -> Bool { self == Self(snapshot.details) }
}

enum GitHubPRStatusStep: String {
  case draft = "convertPullRequestToDraft", ready = "markPullRequestReadyForReview"
  case close = "closePullRequest", reopen = "reopenPullRequest"
  var inputType: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() + "Input" }
  func allowed(_ snapshot: GitHubPRMergeSnapshot) -> Bool {
    let current = GitHubPRStatus(snapshot.details)
    switch self { case .draft: return current == .open; case .ready: return current == .draft
    case .close: return current == .open || current == .draft; case .reopen: return current == .closed }
  }
  func confirmed(_ snapshot: GitHubPRMergeSnapshot) -> Bool {
    switch self {
    case .draft: GitHubPRStatus(snapshot.details) == .draft
    case .ready: GitHubPRStatus(snapshot.details) == .open
    case .close: GitHubPRStatus(snapshot.details) == .closed
    case .reopen: snapshot.details.state.uppercased() == "OPEN"
    }
  }
}

struct GitHubPRStatusFailure: LocalizedError {
  let message: String
  var snapshot: GitHubPRMergeSnapshot? = nil
  var requiresRefresh = false
  var errorDescription: String? { message }
}
