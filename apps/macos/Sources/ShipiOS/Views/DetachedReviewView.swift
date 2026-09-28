import SwiftUI

struct DetachedReviewView: View {
  @Bindable var store: WorkspaceStore
  let owner: String
  let focusComposer: () -> Void
  let openPullRequestLink: @MainActor (URL) async -> Bool
  let openPullRequestDetails: @MainActor (GitHubPullRequest, Bool) async -> Bool
  @FocusedValue(\.searchDialogActive) private var searchDialogActive
  @FocusedValue(\.imagePreviewActive) private var imagePreviewActive
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
    .gitWorkflowPresentation(store: store, workspace: session.workspace, taskID: owner, currentTaskID: {
      store.library.tasks.contains(where: { $0.id == owner }) ? owner : nil
    }, keyboardAllowed: { searchDialogActive != true && imagePreviewActive != true }, openPullRequestLink: openPullRequestLink,
      openPullRequestDetails: openPullRequestDetails) {
      imagePreviewActive != true && !store.shuttingDown && !store.restoringLibrary && store.workspaceTabProject(owner: owner) == session.workspace.root
    }
    .task(id: root) {
      session.configure(store: store, owner: owner)
      if root != nil { await session.workspace.refreshGit() }
    }
    .onChange(of: store.additionalWorkspaceFolders(for: root)) { _, _ in
      session.configure(store: store, owner: owner)
    }
    .onChange(of: session.workspace.reviewScope) { _, _ in session.saveScope(store: store) }
    .onChange(of: session.workspace.selectedReviewRepository) { _, _ in session.saveScope(store: store) }
    .onDisappear { session.saveScope(store: store); session.shutdown() }
  }
}
