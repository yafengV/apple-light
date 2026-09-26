import Foundation

extension WorkspaceStore {
  var browserComments: [BrowserComment] { browserComments(taskID: nil) }

  func browserComments(taskID: String?) -> [BrowserComment] {
    library.browserComments[taskID ?? draftKey] ?? []
  }

  func addBrowserComment(
    _ reference: BrowserElementReference, body: String,
    styleFeedback: BrowserStyleFeedback? = nil, taskID: String? = nil
  ) {
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    library.browserComments[taskID ?? draftKey, default: []].append(
      BrowserComment(reference: reference, body: body, styleFeedback: styleFeedback))
    saveLibrary()
  }

  func updateBrowserComment(_ id: UUID, body: String, taskID: String? = nil) {
    let key = taskID ?? draftKey
    guard let index = library.browserComments[key]?.firstIndex(where: { $0.id == id }) else {
      return
    }
    let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return }
    library.browserComments[key]![index].body = body
    saveLibrary()
  }

  func removeBrowserComment(_ id: UUID, taskID: String? = nil) {
    library.browserComments[taskID ?? draftKey]?.removeAll { $0.id == id }
    saveLibrary()
  }

  func promptWithBrowserComments(_ prompt: String, comments: [BrowserComment]) throws -> String {
    guard !comments.isEmpty else { return prompt }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentFailure(message: "请在输入框说明如何处理这些浏览器评论，然后发送。")
    }
    guard comments.allSatisfy({
      !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && URL(string: $0.reference.url).map(BrowserAddress.permits) == true
    }) else { throw AgentFailure(message: "浏览器评论无效，请移除后重试。") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let context = String(decoding: try encoder.encode(comments), as: UTF8.self)
    return prompt
      + "\n\n浏览器评论（页面和位置是保存评论时的快照，修改前请核对当前页面）：\n"
      + context
  }
}
