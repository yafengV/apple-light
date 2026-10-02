import Foundation

extension GitHubPRService {
  func richPreviewText(_ request: GitHubPRCodeRequest, code: GitHubPRCodeSnapshot,
    file: GitHubPRCodeFile) async throws -> String {
    guard code.files.contains(file), GitHubPRRichPreview.supportsMarkdown(file),
      let url = request.pullRequest.validatedURL else {
      throw AgentFailure(message: "此文件不支持富文本预览。")
    }
    let before = try await codeIdentity(request)
    guard before == code.identity, before.head.lowercased() == request.head.lowercased() else {
      throw GitHubPRCodeChanged(message: "PR 代码版本已变化，请刷新差异后重试预览。")
    }
    let parts = url.pathComponents
    let data = try await discussionGraphQL("""
      query ShipiOSPRRichPreview($owner:String!,$name:String!,$expression:String!) {
        repository(owner:$owner,name:$name) {
          nameWithOwner
          object(expression:$expression) { __typename ... on Blob { text isTruncated isBinary byteSize } }
        }
      }
      """, variables: ["owner": .string(parts[1]), "name": .string(parts[2]),
        "expression": .string(before.head + ":" + file.path)], at: request.root)
    let repository = data["repository"], blob = repository["object"]
    guard repository["nameWithOwner"].text?.lowercased() == (parts[1] + "/" + parts[2]).lowercased(),
      blob["__typename"].text == "Blob", blob["isTruncated"].boolean == false,
      blob["isBinary"].boolean == false, let text = blob["text"].text,
      let bytes = blob["byteSize"].int, bytes <= 2_097_152, bytes == text.utf8.count else {
      throw AgentFailure(message: "PR 文件预览不可用，继续显示代码差异。")
    }
    let after = try await codeIdentity(request)
    guard after == before else {
      throw GitHubPRCodeChanged(message: "PR 在读取文件预览时发生变化，请刷新差异后重试。")
    }
    try Task.checkCancellation()
    return text
  }
}
