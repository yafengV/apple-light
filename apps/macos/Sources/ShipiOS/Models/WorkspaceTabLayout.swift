import Foundation

/// Layout survives choosing the chat tab; selection alone cannot identify it.
enum WorkspaceContentLayoutMode: String, Codable {
  case full, split

  /// Numeric selection follows the primary strip's displayed order, independently
  /// of keyboard focus or whether the split content is currently revealed.
  func numberedTabIDs(_ content: [WorkspaceContentTab], rightToLeft: Bool) -> [String?] {
    let ids: [String?] = (self == .full ? [nil] : []) + content.map { Optional($0.id) }
    return rightToLeft ? Array(ids.reversed()) : ids
  }
}

/// Presentation metadata only. Shell commands, terminal output, page forms and
/// credentials are never replayed by tab restoration.
struct SavedWorkspaceTab: Codable, Equatable {
  var id: String
  var kind: PinnedWorkspaceTabKind
  var placement: WorkspaceTabPlacement
  var address: String?
  var committedURL: String?
  var filePath: String? = nil
  /// Present only for a split terminal. The shell process itself is never restored.
  var terminalSplitFraction: Double? = nil
  var watchAutomationID: UUID? = nil
  var watchTaskID: String? = nil
}

struct WorkspaceTabLayout: Codable, Equatable {
  var tabs: [SavedWorkspaceTab]
  var active: String?
  var right: String?
  var bottom: String?
  var focused: String?
  var showingInspector: Bool
  var showingTerminal: Bool
  var showingTabs: Bool
  var side: WorkspacePaneSide
  var reviewScope: GitReviewScope
  var reviewRepository: String? = nil
  /// Optional for layouts saved before the mode became independent of selection.
  var contentLayoutMode: WorkspaceContentLayoutMode? = nil
}

struct TaskWindowTabLayout: Codable, Equatable {
  var project: String?
  var content: WorkspaceTabLayout
  var panelSizes: WorkspacePanelSizes
  var showingFiles: Bool
}
