import Foundation

struct GitHubPROverviewPresentation: Equatable {
  enum Tone: Equatable { case normal, secondary, success, pending, failure }
  enum Readout: Equatable {
    case loading, failed, value(String, Tone)
  }
  let comments: Readout
  let checks: Readout
  let checksIcon: String

  init(request: GitHubPullRequest, metadata: GitHubPRMergeSnapshot?, loading: Bool, error: String?,
    discussion: GitHubPRDiscussionSnapshot?, discussionError: String?,
    checks: GitHubPRChecksSnapshot?, checksLoading: Bool, checksError: String?) {
    let metadataFailed = !loading && (metadata == nil && error != nil
      || metadata != nil && metadata?.headRevision == nil)
    if let discussion, discussion.requestURL.lowercased() == request.url.lowercased(),
      discussion.head.lowercased() == metadata?.headRevision?.lowercased(), discussionError == nil {
      let count = discussion.overviewCommentCount
      comments = .value(discussion.isActivityPartial ? "已载入 \(count) 条评论" : count == 0 ? "无评论" : "\(count) 条评论", .normal)
    } else { comments = discussionError != nil || metadataFailed ? .failed : .loading }
    if let checks, checks.headRevision.lowercased() == metadata?.headRevision?.lowercased(), !checksLoading {
      let tone: Tone
      if checks.hasReportedFailure || checks.checks.contains(where: { $0.status == .failing }) {
        tone = .failure; checksIcon = "xmark.circle"
      } else if checks.hasPendingChecks { tone = .pending; checksIcon = "circle.lefthalf.filled" }
      else if checks.checks.isEmpty { tone = .normal; checksIcon = "minus.circle" }
      else { tone = .success; checksIcon = "checkmark.circle" }
      self.checks = .value(checks.statusLabel, tone)
    } else {
      self.checks = checksError != nil || metadataFailed ? .failed : .loading
      checksIcon = self.checks == .failed ? "exclamationmark.circle" : "circle.dotted"
    }
  }
}
