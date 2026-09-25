import SwiftUI

struct DetachedReviewView: View {
  @Bindable var store: WorkspaceStore
  let owner: String
  let focusComposer: () -> Void
  @State private var session = DetachedReviewSession()
  private var root: URL? { store.workspaceTabProject(owner: owner) }

  var body: some View {
    Group {
      if let root, session.workspace.root == root {
        GitReviewView(store: store, workspace: session.workspace, taskID: owner, focusComposer: focusComposer)
      } else if root != nil {
        ProgressView("读取审查…")
      } else {
        ContentUnavailableView("原任务的项目不可用", systemImage: "folder.badge.questionmark")
      }
    }
    .task(id: root) {
      session.configure(store: store, owner: owner)
      if root != nil { await session.workspace.refreshGit() }
    }
    .onChange(of: session.workspace.reviewScope) { _, _ in session.saveScope(store: store) }
    .onDisappear { session.saveScope(store: store); session.shutdown() }
  }
}
