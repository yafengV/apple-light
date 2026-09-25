import Foundation

/// Presentation metadata only. Shell commands, terminal output, page forms and
/// credentials are never replayed by tab restoration.
struct SavedWorkspaceTab: Codable, Equatable {
  var id: String
  var kind: PinnedWorkspaceTabKind
  var placement: WorkspaceTabPlacement
  var address: String?
  var committedURL: String?
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
}

struct TaskWindowTabLayout: Codable, Equatable {
  var project: String?
  var content: WorkspaceTabLayout
  var panelSizes: WorkspacePanelSizes
  var showingFiles: Bool
}
