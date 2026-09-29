import Foundation

extension GitHubPRService {
  func generatedAttributes(_ request: GitHubPRCodeRequest, code: GitHubPRCodeSnapshot) async throws -> GitHubPRGeneratedAttributes {
    let before = try await codeIdentity(request)
    guard before == code.identity, before.head.lowercased() == request.head.lowercased(),
      let url = request.pullRequest.validatedURL else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重新读取生成文件规则。")
    }
    var directories = Set([""])
    for file in code.files {
      let parts = file.path.split(separator: "/").map(String.init)
      if parts.count > 1 {
        for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
      }
    }
    let paths = directories.sorted(), parts = url.pathComponents
    let repository = parts[1] + "/" + parts[2]
    var sources: [GitHubPRGeneratedAttributes.Source] = []
    // Read PR head objects from the PR repository, just like Codex. Neither the
    // local checkout's attributes nor global/info attributes enter this view.
    for offset in stride(from: 0, to: paths.count, by: 50) {
      try Task.checkCancellation()
      let batch = Array(paths[offset..<min(paths.count, offset + 50)])
      var variables: [String: JSONValue] = ["owner": .string(parts[1]), "name": .string(parts[2])]
      var definitions: [String] = [], fields: [String] = []
      for (index, base) in batch.enumerated() {
        let key = "p\(index)"
        definitions.append("$\(key):String!")
        variables[key] = .string(before.head + ":" + (base.isEmpty ? "" : base + "/") + ".gitattributes")
        fields.append("f\(index):object(expression:$\(key)) { __typename ... on Blob { text isTruncated isBinary byteSize } }")
      }
      let data = try await discussionGraphQL("""
        query ShipiOSPRGeneratedAttributes($owner:String!,$name:String!,\(definitions.joined(separator: ","))) {
          repository(owner:$owner,name:$name) { nameWithOwner \(fields.joined(separator: "\n")) }
        }
        """, variables: variables, at: request.root)
      let node = data["repository"]
      guard node["nameWithOwner"].text?.lowercased() == repository.lowercased(),
        case .object(let objects) = node else { throw AgentFailure(message: "生成文件规则来源与 PR 仓库不一致。") }
      for (index, base) in batch.enumerated() {
        guard let blob = objects["f\(index)"] else { throw AgentFailure(message: "生成文件规则读取不完整，请重试。") }
        if blob == .null { continue }
        // A path may be a tree or a non-text blob; Codex treats it as no text rule.
        guard let type = blob["__typename"].text, ["Blob", "Tree", "Commit", "Tag"].contains(type) else {
          throw AgentFailure(message: "生成文件规则的对象类型无效，请重新读取。")
        }
        if type != "Blob" { continue }
        guard blob["isTruncated"].boolean == false else {
          throw AgentFailure(message: "生成文件规则被截断，无法确认默认折叠状态。")
        }
        if blob["text"] == .null { continue }
        guard let text = blob["text"].text, blob["isBinary"].boolean != true,
          blob["byteSize"].int == text.utf8.count else {
          throw AgentFailure(message: "生成文件规则内容不完整，请重新读取。")
        }
        sources.append(.init(basePath: base, contents: text))
      }
    }
    let after = try await codeIdentity(request)
    guard after == before else { throw GitHubPRCodeChanged(message: "PR 在读取生成文件规则时发生变化，请刷新差异后重试。") }
    try Task.checkCancellation()
    return try .init(code: code, sources: sources)
  }
}
