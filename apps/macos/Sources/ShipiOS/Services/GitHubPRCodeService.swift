import Foundation

extension GitHubPRService {
  func codeSnapshot(_ request: GitHubPRCodeRequest) async throws -> GitHubPRCodeSnapshot {
    let before = try await codeIdentity(request)
    guard before.head.lowercased() == request.head.lowercased() else {
      throw GitHubPRCodeChanged(message: "PR 头提交已改变，请刷新 PR 后重试。")
    }
    guard let url = request.pullRequest.validatedURL else { throw AgentFailure(message: "PR 地址无效。") }
    let parts = url.pathComponents
    let repository = parts[1] + "/" + parts[2]
    let patch = try await run(["pr", "diff", String(request.pullRequest.number), "--repo", repository,
      "--color", "never"], at: request.root)
    let after = try await codeIdentity(request)
    guard before == after else { throw GitHubPRCodeChanged(message: "PR 在读取差异时发生变化，请刷新后重试。") }
    let files = try GitHubPRCodeFile.parse(patch)
    guard files.count == before.changedFiles else {
      throw AgentFailure(message: "GitHub 返回的差异不完整，无法显示全部修改文件。请重试或在浏览器中查看。")
    }
    try Task.checkCancellation()
    return .init(identity: after, files: files)
  }

  func codeIdentity(_ request: GitHubPRCodeRequest) async throws -> GitHubPRCodeIdentity {
    guard let url = request.pullRequest.validatedURL else { throw AgentFailure(message: "PR 地址无效。") }
    let parts = url.pathComponents, repository = parts[1] + "/" + parts[2]
    let data = try await discussionGraphQL("""
      query ShipiOSPRCodeIdentity($owner:String!,$name:String!,$number:Int!) {
        repository(owner:$owner,name:$name) { nameWithOwner pullRequest(number:$number) {
          id number url headRefOid baseRefOid headRefName baseRefName changedFiles
        } }
      }
      """, variables: ["owner": .string(parts[1]), "name": .string(parts[2]),
        "number": .number(Double(request.pullRequest.number))], at: request.root)
    let node = data["repository"]["pullRequest"]
    guard data["repository"]["nameWithOwner"].text?.lowercased() == repository.lowercased(),
      node["number"].int == request.pullRequest.number, node["url"].text.flatMap(URL.init(string:)) == url,
      let id = node["id"].text, !id.isEmpty,
      let head = node["headRefOid"].text, validCodeRevision(head),
      let base = node["baseRefOid"].text, validCodeRevision(base),
      let headBranch = node["headRefName"].text, let baseBranch = node["baseRefName"].text,
      let count = node["changedFiles"].int, count >= 0 else {
      throw AgentFailure(message: "GitHub 返回的代码版本与当前 PR 不一致。")
    }
    return .init(nodeID: id, head: head, base: base, headBranch: headBranch, baseBranch: baseBranch, changedFiles: count)
  }
  private func validCodeRevision(_ value: String) -> Bool {
    value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
  }
}
