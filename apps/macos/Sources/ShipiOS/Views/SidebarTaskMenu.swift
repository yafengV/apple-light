import SwiftUI

/// Both sidebar surfaces use task identity and the same actions; Activity keeps chronological order.
struct SidebarTaskMenu: View {
  let store: WorkspaceStore
  let taskID: String
  var activity = false

  var body: some View {
    if let task = store.library.tasks.first(where: { $0.id == taskID }) {
      Group {
        Button("重命名…") { store.renameTaskFromMenu(taskID) }
        Button(task.pinned ? "取消置顶" : "置顶任务") { store.toggleTaskPinFromMenu(taskID) }
        Button(store.library.unreadTasks.contains(taskID) ? "标记为已读" : "标记为未读") {
          store.toggleTaskReadFromMenu(taskID)
        }
        if activity {
          Button("归档任务") { Task { await store.archiveActivityTask(taskID) } }
            .disabled(!store.canArchiveActivityTask(taskID))
        } else {
          Button(task.archived ? "恢复任务" : "归档任务") {
            store.updateTask(taskID, archive: !task.archived)
          }.disabled(store.activeRun(taskID: taskID) != nil || store.managedTaskPreparing ||
            store.library.managedWorktrees.contains { $0.taskID == taskID && $0.pendingHandoff != nil })
        }
        Divider()
        SidebarPlacementMenu(store: store, item: .task(taskID), showsOrdering: !activity)
        Divider()
        Menu("复制") {
          Button("工作目录") { store.copyTaskFromMenu(taskID, content: .workingDirectory) }
            .disabled(store.taskMenuWorkingDirectory(task) == nil)
          Button("任务链接") { store.copyTaskFromMenu(taskID, content: .link) }
          Button("会话 Markdown") { store.copyTaskFromMenu(taskID, content: .markdown) }
        }
        if let pending = store.library.managedWorktrees.first(where: { $0.taskID == taskID })?.pendingHandoff {
          Button("继续移交") {
            Task {
              if pending.direction == .toWorktree { await store.handOffTaskToWorktree(taskID) }
              else { await store.handOffTaskToLocal(taskID) }
            }
          }.disabled(!store.canHandOffToWorktree(task) && !store.canHandOffToLocal(task))
        } else if store.library.managedWorktrees.contains(where: {
          $0.taskID == taskID && $0.path == task.project
        }) {
          Button("移交到本地") { Task { await store.handOffTaskToLocal(taskID) } }
            .disabled(!store.canHandOffToLocal(task))
        } else if store.library.projects.contains(task.project), !store.library.isPermanentWorktree(task.project) {
          Button("移交到工作树") { Task { await store.handOffTaskToWorktree(taskID) } }
            .disabled(!store.canHandOffToWorktree(task))
        }
        Divider()
        Button("在新窗口中打开") { store.openTaskInNewWindow(taskID) }
          .disabled(task.archived)
      }.disabled(store.taskMenuTarget(taskID) == nil)
    }
  }
}
