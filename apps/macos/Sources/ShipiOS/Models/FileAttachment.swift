import Foundation

struct FileAttachment: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let byteCount: Int
  let sha256: String
  let isPDF: Bool
  let isDirectory: Bool?

  init(id: UUID, name: String, byteCount: Int, sha256: String, isPDF: Bool,
    isDirectory: Bool = false) {
    self.id = id; self.name = name; self.byteCount = byteCount
    self.sha256 = sha256; self.isPDF = isPDF; self.isDirectory = isDirectory
  }

  var representsDirectory: Bool { isDirectory == true }
}
