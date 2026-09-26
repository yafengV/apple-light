import Foundation

struct GitHubRepository: Equatable, Sendable {
  let owner: String
  let name: String
  var fullName: String { owner + "/" + name }

  static func parse(_ remote: String) throws -> Self {
    let raw: String
    if remote.hasPrefix("git@github.com:") { raw = String(remote.dropFirst("git@github.com:".count)) }
    else if let url = URLComponents(string: remote), url.host?.lowercased() == "github.com",
      ["https", "ssh"].contains(url.scheme), url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil,
      (url.user == nil || (url.scheme == "ssh" && url.user == "git")) {
      raw = String(url.path.drop(while: { $0 == "/" }))
    } else { throw AgentFailure(message: "此 PR 入口目前支持 github.com 仓库，请检查所选远端。") }
    var path = raw
    if path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix(".git") { path.removeLast(4) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
      && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }) else {
      throw AgentFailure(message: "无法识别 GitHub 仓库名称。")
    }
    return Self(owner: parts[0], name: parts[1])
  }

  func pullRequestURL(_ value: String) -> URL? {
    guard let url = URLComponents(string: value), url.scheme == "https", url.host == "github.com",
      url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count == 4, parts[0].lowercased() == owner.lowercased(),
      parts[1].lowercased() == name.lowercased(), parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
    return url.url
  }
}

struct GitHubPullRequest: Codable, Equatable, Sendable {
  let number: Int
  let url: String
  let title: String
  let isDraft: Bool
  let headRefName: String
  let baseRefName: String
  let isCrossRepository: Bool

  var validatedURL: URL? {
    guard number > 0, let components = URLComponents(string: url),
      components.scheme == "https", components.host?.lowercased() == "github.com",
      components.port == nil, components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil else { return nil }
    let parts = components.path.split(separator: "/").map(String.init)
    guard parts.count == 4, parts[2] == "pull", parts[3] == String(number),
      (try? GitHubRepository.parse("https://github.com/\(parts[0])/\(parts[1])")) != nil else { return nil }
    return components.url
  }
}

struct GitHubPRDetails: Decodable, Equatable, Sendable {
  struct Check: Decodable, Equatable, Sendable {
    let name: String?
    let context: String?
    let status: String?
    let conclusion: String?
    let state: String?
  }

  let number: Int
  let url: String
  let title: String
  let body: String?
  let state: String
  let isDraft: Bool
  let headRefName: String
  let baseRefName: String
  let reviewDecision: String?
  let mergeable: String?
  let statusCheckRollup: [Check]?

  var statusLabel: String {
    switch state.uppercased() {
    case "MERGED": "已合并"
    case "CLOSED": "已关闭"
    default: isDraft ? "草稿" : "开放"
    }
  }

  var checkSummary: (passed: Int, failed: Int, pending: Int) {
    var passed = 0, failed = 0, pending = 0
    for check in statusCheckRollup ?? [] {
      let value = (check.conclusion ?? check.state ?? check.status ?? "").uppercased()
      switch value {
      case "SUCCESS", "NEUTRAL", "SKIPPED": passed += 1
      case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED": failed += 1
      default: pending += 1
      }
    }
    return (passed, failed, pending)
  }
}

struct GitHubPRContext: Equatable, Sendable {
  let plan: GitPushPlan
  let repository: GitHubRepository
  let defaultBranch: String
  let existing: GitHubPullRequest?
  let creationProblem: String?
  var head: String { String(plan.destination.dropFirst("refs/heads/".count)) }
}

struct GitHubPRRefreshRequired: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
