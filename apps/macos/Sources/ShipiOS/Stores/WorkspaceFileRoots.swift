import Foundation

extension WorkspaceStore {
  func additionalWorkspaceFolders(for root: URL?) -> [URL] {
    guard let root else { return [] }
    return library.additionalFolders(for: root.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  func synchronizeWorkspaceFileRoots() {
    workspace.setAdditionalFileRoots(additionalWorkspaceFolders(for: workspace.root))
    for sessions in additionalTaskWindowPanels.allObjects {
      for panel in sessions.tasks.values {
        panel.workspace.setAdditionalFileRoots(additionalWorkspaceFolders(for: panel.workspace.root))
      }
    }
  }
}
