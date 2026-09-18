import Foundation

struct FileAttachment: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let byteCount: Int
  let sha256: String
  let isPDF: Bool
}
