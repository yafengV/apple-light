import SwiftUI

/// A background task uses the ordinary transcript and composer without a utility toolbar.
struct PullRequestWatchProgressView: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab
  let close: () -> Void
  var isFocused = true
  var onFocus: (() -> Void)? = nil
  @State private var resources = TaskWindowResources()
  @State private var renameHistory = TaskRenameHistory()

  var body: some View {
    Group {
      if let watch = store.pullRequestWatchContent(tab), let target = watch.taskID {
        if let tabs = resources.tasks[target] {
          TaskWindowView(store: store, taskID: target, tabs: tabs, resources: resources,
            renameHistory: renameHistory,
            onNavigate: { id in
              guard let task = store.library.tasks.first(where: { $0.id == id }) else { return }
              Task { _ = await store.selectTaskAwaitingScope(task) }
            }, canGoBack: false, canGoForward: false, onMove: { _ in },
            backgroundAgent: true, backgroundAgentFocused: isFocused, onCloseBackgroundAgent: close,
            onBackgroundAgentFocus: onFocus)
            .id(target)
        } else { ProgressView("正在打开监控进度…") }
      } else {
        ContentUnavailableView("监控进度不可用", systemImage: "arrow.triangle.pullrequest",
          description: Text("监控或对应任务已删除、归档或改变。"))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("pull-request-watch-progress")
    .task(id: store.pullRequestWatchContent(tab)?.taskID) { prepare() }
    .onChange(of: store.library.tasks.first(where: { $0.id == tab.watchTaskID })?.project) { _, _ in prepare() }
    .onDisappear { resources.shutdown() }
  }

  private func prepare() {
    guard let target = store.pullRequestWatchContent(tab)?.taskID else { return }
    resources.prepare(target, store: store, windowID: "watch-progress:" + tab.id)
    resources.display(target)
  }
}
