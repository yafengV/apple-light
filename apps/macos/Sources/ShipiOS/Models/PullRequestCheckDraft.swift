import Foundation

/// Unsent PR repair context belongs to one task checkout and one pull request.
struct PullRequestCheckDraft: Codable, Equatable, Sendable {
  var id = UUID()
  let root: String
  let pullRequest: GitHubPullRequest
  let headRevision: String
  var checks: [GitHubPRCheck]
  var comments: [PullRequestCommentAttachment] = []
  var generatedPrompt: String? = nil

  var repository: String? {
    guard let url = pullRequest.validatedURL else { return nil }
    return url.pathComponents[1...2].joined(separator: "/")
  }
  var keys: Set<String> { Set(checks.map(\.attachmentKey)) }
  func matches(_ request: GitHubPRChecksRequest) -> Bool {
    root == request.root.path && pullRequest.validatedURL == request.pullRequest.validatedURL
      && pullRequest.number == request.pullRequest.number
  }
  var isValid: Bool {
    !root.isEmpty && pullRequest.validatedURL != nil
      && !pullRequest.headRefName.isEmpty && !pullRequest.baseRefName.isEmpty
      && [40, 64].contains(headRevision.count) && headRevision.allSatisfy { $0.isASCII && $0.isHexDigit }
      && (!checks.isEmpty || !comments.isEmpty) && checks.allSatisfy {
        $0.status == .failing && !$0.name.isEmpty && ($0.link == nil || $0.validatedLink != nil)
      }
      && keys.count == checks.count && comments.allSatisfy(\.isValid)
      && Set(comments.map(\.id)).count == comments.count
  }

  var fixPrompt: String { comments.isEmpty ? ciFixPrompt : commentFixPrompt }

  var commentFixPrompt: String {
    """
    检查 \(repository ?? "") PR #\(pullRequest.number)（\(pullRequest.headRefName) → \(pullRequest.baseRefName)），以最小必要改动处理附加的审查线程和全部回复。
    任务目录是 \(root)。先定位该 PR 的仓库和检出；GitHub CLI 命令明确指定 --repo \(repository ?? "")。
    先核对最新 PR、文件、提交和线程状态，处理每项可执行反馈，不让用户再选择处理哪项。需要澄清、已经过时或不应修改的反馈明确解释，不猜测。
    按每条线程的可选说明处理，不做无关重构。完成后运行相关验证，提交并推送，说明改动和结果；遇到阻碍如实报告。
    """
  }

  var ciFixPrompt: String {
    """
    检查 \(repository ?? "") PR #\(pullRequest.number)（\(pullRequest.headRefName) → \(pullRequest.baseRefName)），针对附加的失败 CI 做最小必要修复。
    任务目录是 \(root)。先定位该 PR 对应的仓库和检出，再修改文件；GitHub CLI 命令明确指定 --repo \(repository ?? "")。
    先用 gh pr view、gh pr checks 确认最新状态，再用 gh run view 查看失败运行、注释和日志。JSON 字段不支持时使用命令实际支持的字段；运行未结束且日志不完整时检查各 job 日志。
    GitHub 信息足够时直接定位并修复。外部 CI 失败先通过 gh 找到对应运行链接，再检查已安装技能、工具以及所需的凭据和权限；缺少访问能力时明确说明缺什么，不猜测日志。
    不做无关重构。修复后运行相关验证，提交并推送，说明原因、改动和结果。遇到阻碍如实报告。
    """
  }

  func appendingContext(to prompt: String) throws -> String {
    guard isValid else { throw AgentFailure(message: "PR 检查附件无效，请移除后重新添加。") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var captured = self; captured.generatedPrompt = nil
    let context = String(decoding: try encoder.encode(captured), as: UTF8.self)
    let intent = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (comments.isEmpty ? "检查并修复附加的失败 CI 检查。" : "处理附加的 PR 审查反馈。") : prompt
    let label = comments.isEmpty ? "附加的 PR 失败检查" : "附加的 PR 审查线程和检查"
    let verify = comments.isEmpty ? "先核对最新运行和日志" : "先核对最新文件、线程、运行和日志"
    return intent + "\n\n" + label + "（添加时的快照；" + verify + "，不能据此假定当前状态）：\n" + context
  }
}

extension PullRequestCheckDraft {
  enum CodingKeys: String, CodingKey { case id, root, pullRequest, headRevision, checks, comments, generatedPrompt }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      root: try c.decode(String.self, forKey: .root), pullRequest: try c.decode(GitHubPullRequest.self, forKey: .pullRequest),
      headRevision: try c.decode(String.self, forKey: .headRevision), checks: try c.decode([GitHubPRCheck].self, forKey: .checks),
      comments: try c.decodeIfPresent([PullRequestCommentAttachment].self, forKey: .comments) ?? [],
      generatedPrompt: try c.decodeIfPresent(String.self, forKey: .generatedPrompt))
  }
}
