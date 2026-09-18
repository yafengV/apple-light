import Foundation

struct ImageAttachment: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let mimeType: String
  let byteCount: Int
  let sha256: String
  var fileExtension: String {
    switch mimeType {
    case "image/jpeg": "jpg"
    case "image/webp": "webp"
    case "image/gif": "gif"
    default: "png"
    }
  }
}

struct ChatMessage: Codable, Equatable, Sendable {
  let role: String
  let content: String
  var images: [ImageAttachment]
  var files: [FileAttachment] = []
  var toolCalls: [ModelFunctionCall] = []
  var toolCallID: String?
  init(role: String, content: String, images: [ImageAttachment] = [], files: [FileAttachment] = [],
    toolCalls: [ModelFunctionCall] = [], toolCallID: String? = nil) {
    self.role = role
    self.content = content
    self.images = images; self.files = files
    self.toolCalls = toolCalls; self.toolCallID = toolCallID
  }
  enum CodingKeys: String, CodingKey { case role, content, images, files, toolCalls, toolCallID }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    role = try c.decode(String.self, forKey: .role)
    content = try c.decode(String.self, forKey: .content)
    images = try c.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
    files = try c.decodeIfPresent([FileAttachment].self, forKey: .files) ?? []
    toolCalls = try c.decodeIfPresent([ModelFunctionCall].self, forKey: .toolCalls) ?? []
    toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
  }
}
