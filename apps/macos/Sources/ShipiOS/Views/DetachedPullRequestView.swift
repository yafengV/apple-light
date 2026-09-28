import SwiftUI

/// The detached PR header owns its command metadata; main-window branch and selection are irrelevant.
struct DetachedPullRequestView: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab
  let close: () -> Void
  @FocusedValue(\.searchDialogActive) private var searchDialogActive
  @State private var session = DetachedReviewSession()
  private var root: URL? { store.workspaceTabProject(owner: tab.owner) }
  private var available: Bool {
    !store.shuttingDown && !store.restoringLibrary && store.pullRequestContent(tab) != nil
      && root != nil && root == session.workspace.root && store.workspaceTabPlacement(tab.id) == .detached
  }

  var body: some View {
    TaskPullRequestTabView(store: store, tab: tab, presentations: store.pullRequestTabPresentations,
      openExternal: { url in Task { _ = await store.openTaskWebLink(url, taskID: tab.owner) } }, close: close)
      .gitWorkflowPresentation(store: store, workspace: session.workspace, taskID: tab.owner,
        currentTaskID: { store.library.tasks.contains(where: { $0.id == tab.owner }) ? tab.owner : nil },
        keyboardAllowed: { searchDialogActive != true }, selectedPullRequest: { store.pullRequestContent(tab) },
        activePullRequestURLs: { tab.pullRequestURL.map { [$0] } ?? [] },
        openPullRequestDetails: { request, confirm in
          guard available, request.url == tab.pullRequestURL else { return false }
          if confirm { store.pullRequestTabPresentations.request(tab.id) }
          return true
        }, available: { available })
      .task(id: root) { session.configure(store: store, owner: tab.owner) }
      .onDisappear { session.shutdown() }
  }
}
