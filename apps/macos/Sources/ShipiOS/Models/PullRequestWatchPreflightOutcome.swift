import Foundation

enum PullRequestWatchPreflightOutcome {
  case blocked(GitHubCLIError.Blocker)
  case merged, closed, checksClear

  static func completion(for details: GitHubPRDetails, preferences: GitPreferences) -> Self? {
    switch details.state.uppercased() {
    case "MERGED": return .merged
    case "CLOSED": return .closed
    case "OPEN":
      guard !preferences.autoMergeWatchedPullRequests,
        preferences.pullRequestWatchInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !details.isDraft, details.mergeable?.uppercased() == "MERGEABLE",
        details.statusCheckRollup != nil, details.checkSummary.failed == 0,
        details.checkSummary.pending == 0 else { return nil }
      return .checksClear
    default: return nil
    }
  }

  var needsInput: Bool {
    if case .blocked = self { return true }
    return false
  }
  var value: String {
    switch self {
    case .blocked: "blocked"
    case .merged: "merged"
    case .closed: "closed"
    case .checksClear: "checks_clear"
    }
  }
  var reason: String {
    switch self {
    case .blocked(let blocker): blocker.reason
    case .merged: "PR 已合并，自动监控已暂停。"
    case .closed: "PR 已关闭，自动监控已暂停。"
    case .checksClear: "PR 无合并冲突，已读取的检查未报告失败或待完成项；自动监控已暂停。"
    }
  }
  var recordName: String { needsInput ? "阻塞记录" : "结束记录" }
  func response(for request: GitHubPullRequest) -> String {
    let heading = "PR #\(request.number) 的监控已暂停" + (needsInput ? "，尚未开始模型修复。" : "。")
    let next: String
    switch self {
    case .blocked(let blocker):
      next = blocker.question + "\n处理后可在本任务继续回复，并恢复监控。"
    case .merged, .closed:
      next = "没有执行新的代码修改或合并操作。监控任务和历史保留，可继续在此任务中回复。"
    case .checksClear:
      next = "PR 仍保持开放，没有执行合并。监控任务和历史保留；需要继续检查时可恢复监控。"
    }
    return heading + "\n" + request.url + "\n\n" + reason + "\n\n" + next
  }
}
