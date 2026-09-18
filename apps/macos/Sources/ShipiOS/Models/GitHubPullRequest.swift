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
