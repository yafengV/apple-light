import AppKit
import SwiftUI

struct GitReviewPullRequestEntry: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let taskID: String?
  let create: () -> Void
  @State private var loader = GitPullRequestEntryLoader()

  var body: some View {
    HStack(spacing: 6) {
      if let existing = loader.readiness?.context.existing, loader.request == request {
        Button {
          let owner = taskID ?? store.selectedTask?.id
          Task { await loader.openExisting(in: workspace, store: store, taskID: owner,
            openURL: { NSWorkspace.shared.open($0) }) }
        } label: {
          Label("查看 PR", systemImage: existing.isDraft ? "doc.badge.ellipsis" : "arrow.triangle.pull")
        }.disabled(loader.opening || request.suspended)
          .help(existing.title)
      } else {
        Button("创建 PR…", action: create).disabled(!canCreate).help(blockedReason)
      }
      if loader.error != nil {
        Button {
          Task { await refresh() }
        } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).disabled(loader.loading || loader.opening || request.suspended)
          .help(loader.error ?? "重新检查 PR").accessibilityLabel("重新检查 PR")
      }
    }
    .task(id: request) { await refresh() }
    .onDisappear { loader.cancel() }
  }

  private var request: GitPullRequestEntryRequest {
    .init(root: workspace.isPrimaryReviewRepository ? workspace.gitRoot : nil,
      revision: workspace.reviewSnapshot, generation: workspace.generationForGitMutation,
      epoch: workspace.reviewRepositoryEpoch, taskID: taskID ?? store.selectedTask?.id,
      suspended: workspace.gitRefreshing || workspace.gitBusy || workspace.gitActionRunning
        || workspace.pullRequestDraft.creating)
  }
  private var canCreate: Bool {
    loader.request == request && !request.suspended && !loader.loading && loader.error == nil
      && workspace.canCommit && workspace.canModifyReview && !store.library.gitPreferences.readOnlyReview
      && loader.readiness?.blockedReason(includeLocalChanges: true) == nil && loader.readiness != nil
  }
  private var blockedReason: String {
    if !workspace.isPrimaryReviewRepository { return "请切换到主仓库以创建 PR" }
    if !workspace.canModifyReview || store.library.gitPreferences.readOnlyReview { return "当前审查为只读" }
    if request.suspended { return "正在处理 Git 操作" }
    if loader.loading || loader.request != request { return "正在检查 PR 状态" }
    return loader.error ?? loader.readiness?.blockedReason(includeLocalChanges: true) ?? "创建主仓库的 PR"
  }
  private func refresh() async {
    let draft = workspace.pullRequestDraft
    await loader.load(request) { try await draft.inspectEntry(at: $0, base: $1) }
  }
}
