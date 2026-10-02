import Foundation

struct ConversationRailItem: Identifiable, Equatable {
  enum PreviewState: Equatable { case ready, loading, unavailable }
  let id: String
  let title: String
  let preview: String
  let date: Date
  let bookmarked: Bool
  var previewState: PreviewState = .ready

  static func steeredID(runID: String, messageID: UUID) -> String {
    "steer:\(runID):\(messageID.uuidString)"
  }
}
