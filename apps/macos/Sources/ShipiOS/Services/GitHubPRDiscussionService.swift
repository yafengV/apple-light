import Foundation

/// Explicit repository scope and private JSON input keep comment text out of CLI arguments.
extension GitHubPRService {
  func discussionGraphQL(_ query: String, variables: [String: JSONValue], at root: URL) async throws -> JSONValue {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-pr-discussion-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("input.json")
    let data = try JSONEncoder().encode(JSONValue.object(["query": .string(query), "variables": .object(variables)]))
    guard FileManager.default.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw AgentFailure(message: "无法创建 PR 请求临时文件。")
    }
    let output: String
    do { output = try await run(["api", "graphql", "--hostname", "github.com", "--input", input.path], at: root) }
    catch {
      if query.hasPrefix("mutation"), [400, 401, 403, 404, 422].contains(where: { error.localizedDescription.contains("(HTTP \($0))") }) {
        throw GitHubPRDiscussionRejected(message: error.localizedDescription)
      }
      throw error
    }
    try Task.checkCancellation()
    let response = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
    if !response["errors"].items.isEmpty {
      let message = response["errors"].items.compactMap { $0["message"].text }.joined(separator: "\n")
      if query.hasPrefix("mutation"), response["data"]["action"] == .null {
        throw GitHubPRDiscussionRejected(message: message)
      }
      throw AgentFailure(message: message)
    }
    guard response["data"] != .null else { throw AgentFailure(message: "GitHub 未返回 PR 数据。") }
    return response["data"]
  }

  static let discussionCommentFields = """
    id body createdAt url author { login __typename avatarUrl } viewerCanUpdate viewerCanDelete
    """
  private static let discussionThreadFields = """
    id path line originalLine diffSide startLine startDiffSide originalStartLine isResolved isOutdated viewerCanReply viewerCanResolve viewerCanUnresolve
    comments(first:100) { totalCount nodes { \(discussionCommentFields) commit { oid } originalCommit { oid } diffHunk } pageInfo { hasNextPage endCursor } }
    """
  private static let discussionIdentityFields = "id number url state headRefOid author { login } createdAt mergedAt mergedBy { login }"

  func discussion(for request: GitHubPullRequest, at root: URL) async throws -> GitHubPRDiscussionSnapshot {
    guard let url = request.validatedURL else { throw AgentFailure(message: "PR 链接无效。") }
    let parts = url.path.split(separator: "/").map(String.init)
    let variables: [String: JSONValue] = ["owner": .string(parts[0]), "name": .string(parts[1]), "number": .number(Double(request.number))]
    let summaryQuery = """
      query ShipiOSPRDiscussionSummary($owner:String!,$name:String!,$number:Int!) {
        viewer { login } repository(owner:$owner,name:$name) { nameWithOwner pullRequest(number:$number) {
          \(Self.discussionIdentityFields)
          commits(last:100) { nodes { commit { oid messageHeadline committedDate url authors(first:1) { nodes { name user { login avatarUrl(size:48) } } } } } pageInfo { hasPreviousPage } }
        } }
      }
      """
    let summary = try await discussionGraphQL(summaryQuery, variables: variables, at: root)
    let identity = try Self.discussionIdentity(summary, request: request, repository: parts[0] + "/" + parts[1])
    let commitPage = summary["repository"]["pullRequest"]["commits"]
    guard case .array(let commitNodes) = commitPage["nodes"], commitNodes.count <= 100,
      let partial = commitPage["pageInfo"]["hasPreviousPage"].boolean else {
      throw AgentFailure(message: "无法确认 PR 提交列表，请重新读取。")
    }
    let commits = commitNodes.compactMap { Self.discussionCommit($0["commit"], request: request) }
    guard Set(commits.map(\.id)).count == commits.count else { throw AgentFailure(message: "PR 提交列表重复，请重新读取。") }
    var comments: [GitHubPRComment] = []
    var threads: [GitHubPRReviewThread] = []
    // Paginate independently: one large connection never truncates another connection.
    for connection in ["comments", "reviews", "reviewThreads"] {
      var cursor: String?, seenCursors: Set<String> = [], seenIDs: Set<String> = [], total: Int?
      var finished = false, receivedCount = 0
      for _ in 0..<100 {
        let fields = connection == "reviewThreads" ? Self.discussionThreadFields
          : Self.discussionCommentFields + (connection == "reviews" ? " state submittedAt commit { oid }" : "")
        let query = """
          query ShipiOSPRDiscussion($owner:String!,$name:String!,$number:Int!,$after:String) {
            viewer { login } repository(owner:$owner,name:$name) { nameWithOwner
              pullRequest(number:$number) { \(Self.discussionIdentityFields)
                \(connection)(first:100,after:$after) { totalCount nodes { \(fields) } pageInfo { hasNextPage endCursor } }
              }
            }
          }
          """
        var pageVariables = variables; pageVariables["after"] = cursor.map(JSONValue.string) ?? .null
        let data = try await discussionGraphQL(query, variables: pageVariables, at: root)
        let pr = data["repository"]["pullRequest"]
        let current = try Self.discussionIdentity(data, request: request, repository: parts[0] + "/" + parts[1])
        try Self.verifyDiscussionIdentity(identity, current)
        let page = pr[connection]
        guard let count = page["totalCount"].int, count >= 0, total == nil || total == count,
          case .array(let nodes) = page["nodes"] else {
          throw AgentFailure(message: "PR 活动在分页期间发生变化，请重新读取。")
        }
        total = count
        receivedCount += nodes.count
        for node in nodes {
          let key = node["id"].text
          if let key {
            guard seenIDs.insert(key).inserted else { throw AgentFailure(message: "PR 活动分页返回重复内容，请重新读取。") }
          }
          if connection == "reviewThreads" {
            threads.append(try await discussionThread(node, at: root))
          } else {
            comments.append(try Self.discussionComment(node, kind: connection == "reviews" ? .review : .issue))
          }
        }
        guard let hasNext = page["pageInfo"]["hasNextPage"].boolean else {
          throw AgentFailure(message: "PR 活动缺少分页状态。")
        }
        if !hasNext {
          guard receivedCount == count else { throw AgentFailure(message: "PR 活动读取不完整。") }
          if seenIDs.count != count { throw AgentFailure(message: "PR 活动读取不完整。") }
          finished = true; break
        }
        guard !nodes.isEmpty, let next = page["pageInfo"]["endCursor"].text, !next.isEmpty,
          seenCursors.insert(next).inserted else { throw AgentFailure(message: "PR 活动分页未能继续。") }
        cursor = next
      }
      guard finished else { throw AgentFailure(message: "PR 活动超出分页读取上限。") }
    }
    let verify = """
      query ShipiOSPRDiscussionIdentity($owner:String!,$name:String!,$number:Int!) {
        viewer { login } repository(owner:$owner,name:$name) { nameWithOwner pullRequest(number:$number) { \(Self.discussionIdentityFields) } }
      }
      """
    let final = try Self.discussionIdentity(await discussionGraphQL(verify, variables: variables, at: root),
      request: request, repository: parts[0] + "/" + parts[1])
    try Self.verifyDiscussionIdentity(identity, final)
    var result = final; result.comments = comments; result.threads = threads; result.events = commits; result.omittedTypes = []; result.isActivityPartial = partial
    return result
  }

  private func discussionThread(_ node: JSONValue, at root: URL) async throws -> GitHubPRReviewThread {
    guard let id = node["id"].text, !id.isEmpty, let path = node["path"].text,
      let resolved = node["isResolved"].boolean, let outdated = node["isOutdated"].boolean else {
      throw AgentFailure(message: "GitHub 评论线程数据不完整。")
    }
    var page = node["comments"], comments: [GitHubPRComment] = [], ids: Set<String> = [], cursors: Set<String> = []
    let total = page["totalCount"].int
    var finished = false
    for _ in 0..<100 {
      guard page["totalCount"].int == total, let total, total >= 0,
        case .array(let nodes) = page["nodes"] else { throw AgentFailure(message: "线程回复在分页期间发生变化。") }
      for node in nodes {
        let comment = try Self.discussionComment(node, kind: .code)
        guard ids.insert(comment.id).inserted else { throw AgentFailure(message: "线程回复分页重复。") }
        comments.append(comment)
      }
      guard let next = page["pageInfo"]["hasNextPage"].boolean else { throw AgentFailure(message: "线程回复缺少分页状态。") }
      if !next {
        guard comments.count == total else { throw AgentFailure(message: "线程回复读取不完整。") }
        finished = true; break
      }
      guard !nodes.isEmpty, let cursor = page["pageInfo"]["endCursor"].text, !cursor.isEmpty,
        cursors.insert(cursor).inserted else { throw AgentFailure(message: "线程回复分页未能继续。") }
      let query = """
        query ShipiOSPRDiscussionReplies($id:ID!,$after:String) {
          node(id:$id) { ... on PullRequestReviewThread { id comments(first:100,after:$after) {
            totalCount nodes { \(Self.discussionCommentFields) commit { oid } originalCommit { oid } diffHunk } pageInfo { hasNextPage endCursor }
          } } }
        }
        """
      let data = try await discussionGraphQL(query, variables: ["id": .string(id), "after": .string(cursor)], at: root)
      guard data["node"]["id"].text == id else { throw AgentFailure(message: "GitHub 返回了其他评论线程。") }
      page = data["node"]["comments"]
    }
    guard finished, !comments.isEmpty else { throw AgentFailure(message: "线程回复读取不完整。") }
    return .init(id: id, path: path, line: node["line"].int, originalLine: node["originalLine"].int,
      diffHunk: node["comments"]["nodes"].items.first?["diffHunk"].text ?? "",
      isResolved: resolved, isOutdated: outdated, canReply: node["viewerCanReply"].boolean == true,
      canResolve: node["viewerCanResolve"].boolean == true, canUnresolve: node["viewerCanUnresolve"].boolean == true,
      comments: comments, diffSide: node["diffSide"].text, startLine: node["startLine"].int,
      startDiffSide: node["startDiffSide"].text, originalStartLine: node["originalStartLine"].int)
  }

  private static func discussionIdentity(_ data: JSONValue, request: GitHubPullRequest, repository: String) throws -> GitHubPRDiscussionSnapshot {
    let pr = data["repository"]["pullRequest"]
    guard data["repository"]["nameWithOwner"].text?.lowercased() == repository.lowercased(),
      pr["number"].int == request.number, pr["url"].text?.lowercased() == request.url.lowercased(),
      let id = pr["id"].text, !id.isEmpty, let viewer = data["viewer"]["login"].text, !viewer.isEmpty,
      let author = pr["author"]["login"].text, !author.isEmpty, let state = pr["state"].text,
      ["OPEN", "CLOSED", "MERGED"].contains(state), let head = pr["headRefOid"].text,
      [40, 64].contains(head.count), head.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
      throw AgentFailure(message: "无法确认 PR、账户或头提交，活动没有载入。")
    }
    return .init(requestURL: request.url, nodeID: id, viewer: viewer, author: author, state: state, head: head,
      comments: [], threads: [], events: [], omittedTypes: [],
      createdAt: pr["createdAt"].text, mergedAt: pr["mergedAt"].text, mergedBy: pr["mergedBy"]["login"].text)
  }
  static func verifyDiscussionIdentity(_ a: GitHubPRDiscussionSnapshot, _ b: GitHubPRDiscussionSnapshot) throws {
    guard a.requestURL.lowercased() == b.requestURL.lowercased(), a.nodeID == b.nodeID,
      a.viewer.lowercased() == b.viewer.lowercased(), a.author.lowercased() == b.author.lowercased(),
      a.head == b.head, a.state == b.state else { throw AgentFailure(message: "PR 或账户在读取期间发生变化，请刷新后继续。") }
  }
  static func discussionComment(_ node: JSONValue, kind: GitHubPRCommentKind) throws -> GitHubPRComment {
    guard let id = node["id"].text, !id.isEmpty, let body = node["body"].text,
      let date = node["createdAt"].text, !date.isEmpty else { throw AgentFailure(message: "GitHub 评论数据不完整。") }
    return .init(id: id, kind: kind, body: body, author: node["author"]["login"].text ?? "未知作者",
      authorType: node["author"]["__typename"].text ?? "User", createdAt: date, url: node["url"].text,
      canUpdate: node["viewerCanUpdate"].boolean == true,
      canDelete: kind != .review && node["viewerCanDelete"].boolean == true,
      reviewState: node["state"].text, commit: node["commit"]["oid"].text, avatarURL: node["author"]["avatarUrl"].text, submittedAt: node["submittedAt"].text, originalCommit: node["originalCommit"]["oid"].text)
  }
  private static func discussionCommit(_ commit: JSONValue, request: GitHubPullRequest) -> GitHubPRActivityEvent? {
    guard let id = commit["oid"].text, !id.isEmpty, let date = commit["committedDate"].text else { return nil }
    let author = commit["authors"]["nodes"].items.first ?? .null
    let fallback = request.validatedURL?.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("commit").appendingPathComponent(id)
    return .init(id: id, kind: "PullRequestCommit", author: author["user"]["login"].text ?? author["name"].text ?? "",
      createdAt: date, text: commit["messageHeadline"].text ?? id,
      url: commit["url"].text ?? fallback?.absoluteString, avatarURL: author["user"]["avatarUrl"].text)
  }
}
