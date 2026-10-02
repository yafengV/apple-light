import Foundation

struct ConversationRailItem: Identifiable, Equatable {
  let id: String
  let title: String
  let preview: String
  let date: Date
  let bookmarked: Bool

  static func steeredID(runID: String, messageID: UUID) -> String {
    "steer:\(runID):\(messageID.uuidString)"
  }
}
