import Foundation

struct GitHubPRReviewer: Equatable, Identifiable, Sendable {
  enum Kind: String, Sendable { case user, team }
  enum Status: String, Sendable {
    case waiting, approved, changesRequested
    var label: String {
      switch self { case .waiting: "等待审查"; case .approved: "已批准"; case .changesRequested: "要求修改" }
    }
  }
  let kind: Kind
  let label: String
  let avatarURL: String?
  var status: Status = .waiting
  var requested = false
  var teamSlug: String? = nil
  var id: String { kind.rawValue + ":" + label.lowercased() }
}

struct GitHubPRReviewersSnapshot: Equatable, Sendable {
  let nodeID: String
  let requestURL: String
  let viewer: String
  let author: String
  let state: String
  var reviewers: [GitHubPRReviewer]
  var canManage: Bool { state == "OPEN" && viewer.lowercased() == author.lowercased() }
}

enum GitHubPRReviewerAction: Equatable, Sendable {
  case request([String])
  case remove(GitHubPRReviewer)
}

struct GitHubPRReviewerFailure: LocalizedError {
  let message: String
  var snapshot: GitHubPRReviewersSnapshot? = nil
  var requiresRefresh = false
  var errorDescription: String? { message }
}
