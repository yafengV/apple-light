import SwiftUI

/// A file content tab owns its editor state, so switching content tabs cannot
/// replace the current draft or scroll position with another file's state.
struct FileWorkspaceTabView: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab
  let openFile: (String) -> Void
  let close: () -> Void
  var fileWorkspace: DeveloperWorkspace? = nil
  var fileRoot: URL? = nil

  private var path: String {
    guard case .file(let path, _) = tab else { return "" }
    return path
  }
  private var root: URL? { fileWorkspace == nil ? store.workspaceFileTabRoot(tab) : fileRoot }
  private var contentWorkspace: DeveloperWorkspace { fileWorkspace ?? store.fileTabWorkspace(tab) }
  private var folders: [URL] { store.additionalWorkspaceFolders(for: root) }
  private var scopeKey: String {
    ([tab.id, root?.path ?? ""] + folders.map(\.path)).joined(separator: "\u{0}")
  }

  var body: some View {
    Group {
      if let root {
        let editor = contentWorkspace
        FileWorkspaceView(store: store, workspace: editor,
          taskID: tab.owner.hasPrefix("new:") ? nil : tab.owner,
          draftOwner: tab.owner,
          openInContentTab: openFile, closeContentTab: {
            if fileWorkspace == nil { store.closeFileContentTab(tab, editor: editor) }
            else { close() }
          })
          .task(id: scopeKey) {
            guard !Task.isCancelled else { return }
            let workspace = contentWorkspace
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
    let context = FileEditorRecoveryContext.file(tab)
    if let existing = fileTabWorkspaces[tab.id] {
      if existing.fileEditorRecoveryContext != context { bindFileEditorRecovery(to: existing, context: context) }
      return existing
    }
    let workspace = DeveloperWorkspace()
    bindFileEditorRecovery(to: workspace, context: context)
    fileTabWorkspaces[tab.id] = workspace
    return workspace
  }
}
