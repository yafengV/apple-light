import Foundation

struct ConversationReadingRevision: Equatable {
  let id: String
  let updatedAt: Double
  let status: String
}

struct ConversationReadingPosition {
  let metrics: ConversationScrollMetrics
  let followsLatest: Bool
  let hasNewContent: Bool
  let revisions: [ConversationReadingRevision]
}

/// Each window owns its cache; this session state does not retain native views.
@MainActor final class ConversationReadingPositions {
  private var positions: [String: ConversationReadingPosition] = [:]
  private var consumedRevealID: UUID?
  func hasConsumedReveal(_ id: UUID) -> Bool { consumedRevealID == id }
  func consumeReveal(_ id: UUID) { consumedRevealID = id }
  func position(for taskID: String) -> ConversationReadingPosition? { positions[taskID] }
  func remember(_ taskID: String, metrics: ConversationScrollMetrics?, state: ConversationScrollState,
    revisions: [ConversationReadingRevision]) {
    guard !taskID.isEmpty, let metrics, metrics.viewportHeight > 0,
      metrics.offset.isFinite, metrics.contentHeight.isFinite, metrics.viewportHeight.isFinite else { return }
    positions[taskID] = .init(metrics: metrics, followsLatest: state.followsLatest,
      hasNewContent: state.hasNewContent, revisions: revisions)
  }
}
