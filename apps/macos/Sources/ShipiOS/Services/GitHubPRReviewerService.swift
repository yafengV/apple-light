import Foundation

extension GitHubPRService {
  private static let reviewerIdentityFields = "id number url state author { login }"

  private static func reviewerIdentity(_ data: JSONValue, request: GitHubPullRequest) throws -> GitHubPRReviewersSnapshot {
    guard let url = request.validatedURL else { throw AgentFailure(message: "PR 链接无效。") }
    let parts = url.path.split(separator: "/")
    let pr = data["repository"]["pullRequest"]
    guard data["repository"]["nameWithOwner"].text?.lowercased() == "\(parts[0])/\(parts[1])".lowercased(),
      pr["number"].int == request.number, pr["url"].text?.lowercased() == url.absoluteString.lowercased(),
      let id = pr["id"].text, !id.isEmpty, let viewer = data["viewer"]["login"].text, !viewer.isEmpty,
      let author = pr["author"]["login"].text, !author.isEmpty, let state = pr["state"].text,
      ["OPEN", "CLOSED", "MERGED"].contains(state) else {
      throw AgentFailure(message: "GitHub 账户、仓库或 PR 数据无法确认。")
    }
    return .init(nodeID: id, requestURL: url.absoluteString, viewer: viewer, author: author, state: state, reviewers: [])
  }

  func reviewers(for request: GitHubPullRequest, at root: URL) async throws -> GitHubPRReviewersSnapshot {
    guard let url = request.validatedURL else { throw AgentFailure(message: "PR 链接无效。") }
    let parts = url.path.split(separator: "/").map(String.init)
    var identity: GitHubPRReviewersSnapshot?
    var requested: [GitHubPRReviewer] = [], reviewed: [GitHubPRReviewer] = []
    var requestedCursor: String?, reviewCursor: String?
    var finished: Set<String> = [], cursors: [String: Set<String>] = [:]
    var totals: [String: Int] = [:], counts: [String: Int] = [:], seen: [String: Set<String>] = [:]
    let query = """
      query ShipiOSPRReviewers($owner:String!,$name:String!,$number:Int!,$requestsAfter:String,$reviewsAfter:String) {
        viewer { login } repository(owner:$owner,name:$name) { nameWithOwner pullRequest(number:$number) {
          \(Self.reviewerIdentityFields)
          reviewRequests(first:100,after:$requestsAfter) { totalCount nodes { requestedReviewer {
            __typename ... on User { login avatarUrl(size:40) } ... on Team { name slug }
            ... on Bot { login avatarUrl(size:40) } ... on Mannequin { login avatarUrl(size:40) }
          } } pageInfo { hasNextPage endCursor } }
          latestReviews(first:100,after:$reviewsAfter) { totalCount nodes { id state author { login avatarUrl } }
            pageInfo { hasNextPage endCursor } }
        } }
      }
      """
    for _ in 0..<100 {
      let data = try await discussionGraphQL(query, variables: ["owner": .string(parts[0]), "name": .string(parts[1]),
        "number": .number(Double(request.number)), "requestsAfter": requestedCursor.map(JSONValue.string) ?? .null,
        "reviewsAfter": reviewCursor.map(JSONValue.string) ?? .null], at: root)
      let current = try Self.reviewerIdentity(data, request: request)
      if let identity, identity != current { throw AgentFailure(message: "PR 或 GitHub 账户在读取审查者时改变，请刷新。") }
      identity = current
      for name in ["reviewRequests", "latestReviews"] where !finished.contains(name) {
        let page = data["repository"]["pullRequest"][name]
        guard let total = page["totalCount"].int, total >= 0, totals[name] == nil || totals[name] == total,
          case .array(let nodes) = page["nodes"], nodes.count <= 100,
          let hasNext = page["pageInfo"]["hasNextPage"].boolean else {
          throw AgentFailure(message: "审查者列表不完整或在分页期间改变，请刷新。")
        }
        totals[name] = total; counts[name, default: 0] += nodes.count
        for node in nodes {
          if name == "reviewRequests" {
            let reviewer = node["requestedReviewer"]
            let team = reviewer["__typename"].text == "Team"
            guard ["User", "Team", "Bot", "Mannequin"].contains(reviewer["__typename"].text ?? ""),
              let label = reviewer[team ? "name" : "login"].text, !label.isEmpty else {
              throw AgentFailure(message: "GitHub 返回了无效的待审查者。")
            }
            let item = GitHubPRReviewer(kind: team ? .team : .user, label: label,
              avatarURL: reviewer["avatarUrl"].text, requested: true, teamSlug: team ? reviewer["slug"].text : nil)
            guard seen[name, default: []].insert(item.id).inserted,
              !team || (item.teamSlug?.isEmpty == false) else { throw AgentFailure(message: "审查者分页重复或团队标识缺失。") }
            requested.append(item)
          } else {
            guard let id = node["id"].text, seen[name, default: []].insert(id).inserted,
              let state = node["state"].text else { throw AgentFailure(message: "审查结果分页重复或缺少状态。") }
            if let login = node["author"]["login"].text, !login.isEmpty,
              ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"].contains(state) {
              reviewed.append(.init(kind: .user, label: login, avatarURL: node["author"]["avatarUrl"].text,
                status: state == "APPROVED" ? .approved : state == "CHANGES_REQUESTED" ? .changesRequested : .waiting))
            }
          }
        }
        if !hasNext {
          guard counts[name] == total else { throw AgentFailure(message: "审查者分页读取不完整。") }
          finished.insert(name)
        } else {
          guard !nodes.isEmpty, let cursor = page["pageInfo"]["endCursor"].text, !cursor.isEmpty,
            cursors[name, default: []].insert(cursor).inserted else { throw AgentFailure(message: "审查者分页未能继续。") }
          if name == "reviewRequests" { requestedCursor = cursor } else { reviewCursor = cursor }
        }
      }
      if finished.count == 2 { break }
    }
    guard finished.count == 2, var identity else { throw AgentFailure(message: "审查者超出分页读取上限。") }
    // Match the reference ordering: requests, teams, approved, changes requested, comments.
    reviewed = reviewed.filter { $0.status == .approved } + reviewed.filter { $0.status == .changesRequested }
      + reviewed.filter { $0.status == .waiting }
    var combined = requested.filter { $0.kind == .user } + requested.filter { $0.kind == .team }
    for reviewer in reviewed {
      if let index = combined.firstIndex(where: { $0.id == reviewer.id }) {
        combined[index].status = reviewer.status
        combined[index] = .init(kind: combined[index].kind, label: combined[index].label,
          avatarURL: combined[index].avatarURL ?? reviewer.avatarURL, status: combined[index].status,
          requested: combined[index].requested, teamSlug: combined[index].teamSlug)
      } else { combined.append(reviewer) }
    }
    identity.reviewers = combined
    return identity
  }

  func reviewerCandidates(request: GitHubPullRequest, expected: GitHubPRReviewersSnapshot,
    query: String, at root: URL) async throws -> [GitHubPRMentionUser] {
    guard let url = request.validatedURL, !query.isEmpty, query.utf8.count <= 256,
      !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw AgentFailure(message: "审查者搜索内容无效。")
    }
    let parts = url.path.split(separator: "/").map(String.init)
    let graph = """
      query ShipiOSPRReviewerCandidates($owner:String!,$name:String!,$number:Int!,$search:String!) {
        viewer { login } repository(owner:$owner,name:$name) { nameWithOwner
          collaborators(first:100,query:$search) { nodes { login avatarUrl(size:40) } }
          pullRequest(number:$number) { \(Self.reviewerIdentityFields) }
        }
      }
      """
    let data = try await discussionGraphQL(graph, variables: ["owner": .string(parts[0]), "name": .string(parts[1]),
      "number": .number(Double(request.number)), "search": .string(query)], at: root)
    let identity = try Self.reviewerIdentity(data, request: request)
    guard identity.nodeID == expected.nodeID, identity.viewer.lowercased() == expected.viewer.lowercased(),
      identity.canManage, case .array(let nodes) = data["repository"]["collaborators"]["nodes"] else {
      throw AgentFailure(message: "PR 或 GitHub 账户已改变，审查者候选未载入。")
    }
    var seen: Set<String> = []
    return try nodes.compactMap { node in
      guard let login = node["login"].text, !login.isEmpty,
        login.utf16.allSatisfy(GitHubPRMentionToken.isLoginCharacter) else { throw AgentFailure(message: "审查者用户名无效。") }
      guard login.lowercased() != identity.author.lowercased(), seen.insert(login.lowercased()).inserted else { return nil }
      return .init(login: login, avatarURL: node["avatarUrl"].text)
    }
  }

  func updateReviewers(_ action: GitHubPRReviewerAction, request: GitHubPullRequest,
    expected: GitHubPRReviewersSnapshot, at root: URL, authorize: GitMutationAuthorization = {}) async throws -> GitHubPRReviewersSnapshot {
    try await authorize()
    let fresh = try await reviewers(for: request, at: root)
    guard fresh.nodeID == expected.nodeID, fresh.viewer.lowercased() == expected.viewer.lowercased(), fresh.canManage else {
      throw GitHubPRReviewerFailure(message: "只有开放 PR 的作者可以管理审查者；请刷新当前账户和状态。", snapshot: fresh)
    }
    var users: [String] = [], teams: [String] = []
    let method: String
    switch action {
    case .request(let logins):
      method = "POST"
      var seen: Set<String> = []
      for login in logins {
        guard !login.isEmpty, login.utf16.allSatisfy(GitHubPRMentionToken.isLoginCharacter),
          login.lowercased() != fresh.author.lowercased() else { throw AgentFailure(message: "审查者用户名无效，或为 PR 作者本人。") }
        if fresh.reviewers.contains(where: { $0.kind == .user && $0.label.lowercased() == login.lowercased() }) { continue }
        if seen.insert(login.lowercased()).inserted { users.append(login) }
      }
    case .remove(let reviewer):
      method = "DELETE"
      guard let current = fresh.reviewers.first(where: { $0.id == reviewer.id && $0.requested }) else { return fresh }
      if current.kind == .team {
        guard let slug = current.teamSlug, !slug.isEmpty else { throw AgentFailure(message: "无法确认审查团队标识。") }
        teams = [slug]
      } else { users = [current.label] }
    }
    if users.isEmpty && teams.isEmpty { return fresh }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-pr-reviewers-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("input.json")
    let data = try JSONEncoder().encode(JSONValue.object(["reviewers": .array(users.map(JSONValue.string)),
      "team_reviewers": .array(teams.map(JSONValue.string))]))
    guard FileManager.default.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600]),
      let url = request.validatedURL else { throw AgentFailure(message: "无法创建审查者请求。") }
    let parts = url.path.split(separator: "/")
    try Task.checkCancellation(); try await authorize()
    var writeError: Error?
    do {
      _ = try await run(["api", "repos/\(parts[0])/\(parts[1])/pulls/\(request.number)/requested_reviewers",
        "--hostname", "github.com", "--method", method, "--input", input.path], at: root)
    } catch is CancellationError { throw CancellationError() }
    catch { writeError = error }
    try Task.checkCancellation()
    do {
      let result = try await reviewers(for: request, at: root)
      guard result.nodeID == fresh.nodeID, result.viewer.lowercased() == fresh.viewer.lowercased() else {
        throw AgentFailure(message: "账户或 PR 在操作后改变。")
      }
      let confirmed: Bool
      switch action {
      case .request:
        // A requested user may have already submitted their review by the reread.
        confirmed = users.allSatisfy { name in result.reviewers.contains { $0.kind == .user && $0.label.lowercased() == name.lowercased() } }
      case .remove(let reviewer): confirmed = !result.reviewers.contains { $0.id == reviewer.id && $0.requested }
      }
      guard confirmed else { throw GitHubPRReviewerFailure(message: writeError?.localizedDescription ?? "操作结果尚未确认，请刷新。", snapshot: result, requiresRefresh: true) }
      return result
    } catch is CancellationError { throw CancellationError() }
    catch let error as GitHubPRReviewerFailure { throw error }
    catch { throw GitHubPRReviewerFailure(message: "操作结果尚未确认，请刷新：" + (writeError ?? error).localizedDescription, requiresRefresh: true) }
  }
}
