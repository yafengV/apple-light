import Foundation

extension GitHubPRService {
  private struct CheckRun: Decodable {
    let id: Int64
    let name: String
    let status: String?
    let conclusion: String?
    let head_sha: String
    let details_url: String?
    let html_url: String?
  }
  private struct CheckRunsPage: Decodable {
    let total_count: Int
    let check_runs: [CheckRun]
  }
  private struct CommitStatus: Decodable {
    let context: String
    let state: String
    let target_url: String?
    let description: String?
  }
  private struct CommitStatusPage: Decodable {
    let sha: String
    let state: String
    let total_count: Int
    let statuses: [CommitStatus]
  }
  private struct CheckSuites: Decodable {
    struct Suite: Decodable { let head_sha: String }
    let total_count: Int
    let check_suites: [Suite]
  }
  private struct CheckRead: Sendable {
    var checks: [GitHubPRCheck] = []
    var complete = false
    var hasFailure = false
    var hasPending = false
    var error: String?
  }

  /// Both APIs read an immutable commit, and a final PR read rejects a changed head or base.
  func checks(_ request: GitHubPRChecksRequest) async throws -> GitHubPRChecksSnapshot {
    let head = request.headRevision
    guard [40, 64].contains(head.count), head.allSatisfy({ $0.isASCII && $0.isHexDigit }),
      let url = request.pullRequest.validatedURL else { throw AgentFailure(message: "无法确认 PR 检查的头提交。") }
    let parts = url.pathComponents
    let repository = try GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])")
    let before = try await details(for: request.pullRequest, at: request.root)
    guard before.headRefOid?.lowercased() == head.lowercased() else {
      throw GitHubPRRefreshRequired(message: "PR 头提交已变化，请刷新 PR 状态后重试。")
    }
    if before.state.uppercased() != "OPEN" {
      return .init(headRevision: head, checks: [], complete: true, pullRequestState: before.state)
    }
    let endpoint = "repos/" + repository.fullName + "/commits/" + head
    async let runs = checkRuns(endpoint + "/check-runs", head: head, at: request.root)
    async let statuses = commitStatuses(endpoint + "/status", head: head, at: request.root)
    async let suites = checkSuitesComplete(endpoint + "/check-suites?per_page=1", head: head, at: request.root)
    let (runResult, statusResult, suitesComplete) = await (runs, statuses, suites)
    try Task.checkCancellation()
    let after = try await details(for: request.pullRequest, at: request.root)
    guard after.headRefOid?.lowercased() == head.lowercased(),
      after.headRefName == before.headRefName, after.baseRefName == before.baseRefName else {
      throw GitHubPRRefreshRequired(message: "PR 分支或头提交已变化，请刷新 PR 状态后重试。")
    }
    guard runResult.error == nil || statusResult.error == nil
      || !runResult.checks.isEmpty || !statusResult.checks.isEmpty else {
      throw AgentFailure(message: "无法读取 PR 检查。\n" + [runResult.error, statusResult.error].compactMap { $0 }.joined(separator: "\n"))
    }
    return .init(headRevision: head, checks: statusResult.checks + runResult.checks,
      complete: runResult.complete && suitesComplete && statusResult.complete, pullRequestState: after.state,
      hasReportedFailure: runResult.hasFailure || statusResult.hasFailure,
      hasReportedPending: runResult.hasPending || statusResult.hasPending)
  }

  private func readCheckPage(_ endpoint: String, at root: URL) async throws -> String {
    try await run(["api", "--method", "GET", "--hostname", "github.com", endpoint], at: root)
  }
  private func checkRuns(_ endpoint: String, head: String, at root: URL) async -> CheckRead {
    var result = CheckRead(), seen = Set<Int64>(), total: Int?
    // Codex limits each source to 20 pages of 100 and treats page drift as partial.
    for index in 1...20 {
      do {
        let text = try await readCheckPage(endpoint + "?per_page=100&page=\(index)&filter=latest", at: root)
        let page = try JSONDecoder().decode(CheckRunsPage.self, from: Data(text.utf8))
        guard page.total_count >= 0,
          page.check_runs.allSatisfy({ $0.head_sha.lowercased() == head.lowercased() && $0.id > 0 }) else {
          throw AgentFailure(message: "检查结果的头提交或标识无效。")
        }
        var duplicate = false
        for check in page.check_runs {
          let status = GitHubPRCheckStatus.checkRun(status: check.status, conclusion: check.conclusion)
          result.hasFailure = result.hasFailure || status == .failing
          guard seen.insert(check.id).inserted else { duplicate = true; continue }
          result.checks.append(.init(id: "check-run:\(check.id)", name: check.name, status: status,
            link: (GitHubPRCheck.webLink(check.details_url) ?? GitHubPRCheck.webLink(check.html_url))?.absoluteString,
            description: nil))
        }
        if total == nil { total = page.total_count }
        guard !duplicate, total == page.total_count, page.check_runs.count <= 100 else { return result }
        if result.checks.count == total { result.complete = true; return result }
        guard result.checks.count < (total ?? 0), page.check_runs.count == 100 else { return result }
      } catch { result.error = error.localizedDescription; return result }
    }
    return result
  }
  private func commitStatuses(_ endpoint: String, head: String, at root: URL) async -> CheckRead {
    var result = CheckRead(), seen = Set<String>(), total: Int?
    for index in 1...20 {
      do {
        let text = try await readCheckPage(endpoint + "?per_page=100&page=\(index)", at: root)
        let page = try JSONDecoder().decode(CommitStatusPage.self, from: Data(text.utf8))
        guard page.sha.lowercased() == head.lowercased(), page.total_count >= 0,
          ["failure", "pending", "success"].contains(page.state),
          page.statuses.allSatisfy({ !$0.context.isEmpty }) else {
          throw AgentFailure(message: "提交状态的头提交或内容无效。")
        }
        result.hasFailure = result.hasFailure || page.state == "failure"
        result.hasPending = result.hasPending || (page.state == "pending" && page.total_count > 0)
        var duplicate = false
        for check in page.statuses {
          let status = GitHubPRCheckStatus.completed(check.state)
          result.hasFailure = result.hasFailure || status == .failing
          // The reference's read identities preserve the API context spelling.
          guard seen.insert(check.context).inserted else { duplicate = true; continue }
          result.checks.append(.init(id: "commit-status:" + check.context,
            name: check.context, status: status, link: check.target_url, description: check.description))
        }
        if total == nil { total = page.total_count }
        guard !duplicate, total == page.total_count, page.statuses.count <= 100 else { return result }
        if result.checks.count == total { result.complete = true; return result }
        guard result.checks.count < (total ?? 0), page.statuses.count == 100 else { return result }
      } catch { result.error = error.localizedDescription; return result }
    }
    return result
  }
  private func checkSuitesComplete(_ endpoint: String, head: String, at root: URL) async -> Bool {
    do {
      let text = try await readCheckPage(endpoint, at: root)
      let suites = try JSONDecoder().decode(CheckSuites.self, from: Data(text.utf8))
      return (0...1000).contains(suites.total_count)
        && (suites.total_count == 0 || !suites.check_suites.isEmpty)
        && suites.check_suites.allSatisfy { $0.head_sha.lowercased() == head.lowercased() }
    } catch { return false }
  }
}
