import SwiftUI

private struct TurnReviewRouteKey: EnvironmentKey {
  static let defaultValue: ((AgentRun) -> Bool)? = nil
}
extension EnvironmentValues {
  var turnReviewRoute: ((AgentRun) -> Bool)? {
    get { self[TurnReviewRouteKey.self] }
    set { self[TurnReviewRouteKey.self] = newValue }
  }
}

extension WorkspaceStore {
  /// Reuse the read-only latest-turn review. Historical cards keep their exact
  /// private snapshot viewer instead of silently opening a different turn.
  @discardableResult func openTurnReview(runID: String) -> Bool {
    guard destination == .workspace, !libraryRecoveryBlocksInteraction,
      presentedOverlay == nil, !hasSettingsConfirmation, let task = selectedTask,
      project != nil, task.runIDs.contains(runID),
      let source = lastTurnReviewSource(taskID: task.id), source.runID == runID,
      source.diff != nil else { return false }
    workspaceContentLayoutMode = .split
    openReviewTab(in: .right)
    workspace.selectedReviewScope = .lastTurn
    return true
  }
}
