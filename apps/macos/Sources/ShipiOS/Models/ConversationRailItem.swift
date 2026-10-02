import Foundation

struct ConversationRailItem: Identifiable, Equatable {
  enum PreviewState: Equatable { case ready, loading, unavailable }
  struct Output: Equatable, Identifiable {
    enum Kind: Equatable { case file, image, website }
    let id: String
    let label: String
    let kind: Kind

    var icon: String {
      switch kind {
      case .file: "doc.text"
      case .image: "photo"
      case .website: "globe"
      }
    }
  }
  let id: String
  let title: String
  let preview: String
  let date: Date
  let bookmarked: Bool
  var previewState: PreviewState = .ready
  var outputs: [Output] = []
  var additionalOutputCount = 0

  static func steeredID(runID: String, messageID: UUID) -> String {
    "steer:\(runID):\(messageID.uuidString)"
  }
}
