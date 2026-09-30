import SwiftUI

/// A file content tab owns its editor state, so switching content tabs cannot
/// replace the current draft or scroll position with another file's state.
struct FileWorkspaceTabView: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab
  let openFile: (String) -> Void
  let close: () -> Void

  private var path: String {
    guard case .file(let path, _) = tab else { return "" }
    return path
  }
  private var root: URL? { store.workspaceTabProject(owner: tab.owner) }
  private var folders: [URL] { store.additionalWorkspaceFolders(for: root) }
  private var scopeKey: String {
    ([tab.id, root?.path ?? ""] + folders.map(\.path)).joined(separator: "\u{0}")
  }

  var body: some View {
    Group {
      if let root {
        FileWorkspaceView(store: store, workspace: store.fileTabWorkspace(tab),
          taskID: tab.owner.hasPrefix("new:") ? nil : tab.owner,
          draftOwner: tab.owner,
          openInContentTab: openFile, closeContentTab: close)
          .task(id: scopeKey) {
            let workspace = store.fileTabWorkspace(tab)
            if workspace.root != root {
              if workspace.root != nil { store.captureFileEditorRecovery(from: workspace) }
              workspace.setProject(root, additionalFolders: folders)
            } else {
              workspace.setAdditionalFileRoots(folders)
            }
            if !path.isEmpty, workspace.selectedFile != path {
              await workspace.openFile(path)
              workspace.fileFocusRequest = UUID()
            }
            await workspace.refreshFiles()
          }
      } else {
        ContentUnavailableView("项目不可用", systemImage: "folder.badge.questionmark",
          description: Text("此文件所属的项目可能已移除。"))
      }
    }
  }
}

extension WorkspaceStore {
  func fileTabWorkspace(_ tab: WorkspaceContentTab) -> DeveloperWorkspace {
    if let existing = fileTabWorkspaces[tab.id] { return existing }
    let workspace = DeveloperWorkspace()
    bindFileEditorRecovery(to: workspace)
    fileTabWorkspaces[tab.id] = workspace
    return workspace
  }
}
