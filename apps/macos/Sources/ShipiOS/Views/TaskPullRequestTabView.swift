import SwiftUI

struct TaskPullRequestTabView: View {
  let store: WorkspaceStore
  let tab: WorkspaceContentTab
  let presentations: PullRequestTabPresentations
  let openExternal: (URL) -> Void
  let close: () -> Void
  var focusComposer: (() -> Void)? = nil

  var body: some View {
    if let request = store.pullRequestContent(tab),
      let task = store.library.tasks.first(where: { $0.id == tab.owner }) {
      TaskPullRequestDetailView(store: store, taskID: tab.owner, request: request,
        root: URL(fileURLWithPath: task.project), openExternal: openExternal,
        onRefresh: { _ = store.updateRecordedPullRequest($0, for: tab.owner) },
        back: {}, close: close, focusComposer: focusComposer, compact: false, presentations: presentations, tabID: tab.id)
        .id(tab.id)
    } else {
      ContentUnavailableView("PR 不可用", systemImage: "arrow.triangle.pullrequest",
        description: Text("此任务或关联 PR 可能已移除。"))
    }
  }
}
