import Foundation

extension GitHubPRService {
  func mentionUsers(_ context: GitHubPRMentionRequest, query: String) async throws -> [GitHubPRMentionUser] {
    guard let url = context.pullRequest.validatedURL, !context.viewer.isEmpty,
      query.utf8.count <= 256, query.utf16.allSatisfy(GitHubPRMentionToken.isLoginCharacter) else {
      throw AgentFailure(message: "无法确认 PR 用户查询范围。")
    }
    let parts = url.path.split(separator: "/").map(String.init)
    let graphQL = """
      query ShipiOSPRMentionUsers($owner:String!,$name:String!,$number:Int!,$search:String!) {
        viewer { login } repository(owner:$owner,name:$name) { nameWithOwner
          mentionableUsers(first:10,query:$search) { nodes { login avatarUrl(size:48) } }
          pullRequest(number:$number) { number url participants(first:100) { nodes { login avatarUrl(size:48) } } }
        }
      }
      """
    let data = try await discussionGraphQL(graphQL, variables: ["owner": .string(parts[0]), "name": .string(parts[1]),
      "number": .number(Double(context.pullRequest.number)), "search": .string(query)], at: context.root)
    let repo = data["repository"], pr = repo["pullRequest"]
    guard data["viewer"]["login"].text?.lowercased() == context.viewer.lowercased(),
      repo["nameWithOwner"].text?.lowercased() == (parts[0] + "/" + parts[1]).lowercased(),
      pr["number"].int == context.pullRequest.number, pr["url"].text?.lowercased() == context.pullRequest.url.lowercased(),
      case .array(let participants) = pr["participants"]["nodes"],
      case .array(let mentionable) = repo["mentionableUsers"]["nodes"] else {
      throw AgentFailure(message: "GitHub 账户或 PR 已改变，用户候选未载入。")
    }
    var users: [GitHubPRMentionUser] = [], seen: Set<String> = []
    for node in participants.filter({ query.isEmpty || $0["login"].text?.lowercased().contains(query.lowercased()) == true })
      + (query.isEmpty ? [] : mentionable) {
      guard let login = node["login"].text, !login.isEmpty, login.utf16.allSatisfy(GitHubPRMentionToken.isLoginCharacter) else {
        throw AgentFailure(message: "GitHub 返回了无效的用户候选。")
      }
      if seen.insert(login.lowercased()).inserted { users.append(.init(login: login, avatarURL: node["avatarUrl"].text)) }
    }
    return query.isEmpty ? users : Array(users.prefix(10))
  }
}
