import Foundation

struct SubagentDraftScope: Codable, Hashable, Sendable {
  let taskID: String
  let rootThreadID: String
  let childThreadID: String
}

struct SubagentDraft: Codable, Equatable, Sendable {
  let scope: SubagentDraftScope
  var message: ChatMessage
  var contentRevision = UUID()
  var isEmpty: Bool { message.content.isEmpty && message.images.isEmpty && message.files.isEmpty }
}
