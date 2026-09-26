import SwiftUI

struct SidebarTaskRow: View {
  let store: WorkspaceStore
  let task: WorkspaceTask
  var showsProject = false
  private var run: AgentRun? {
    task.runIDs.last.flatMap { id in
      store.runs.first { $0.id == id } ?? store.library.localRuns.first { $0.id == id }
    }
  }
  var body: some View {
    let attention = store.taskAttentionKind(for: task)
    Button {
      store.selectTask(task)
    } label: {
      HStack(spacing: 8) {
        if attention == .approval {
          Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            .accessibilityLabel("等待工具批准")
        } else if attention == .question {
          Image(systemName: "questionmark.bubble.fill").foregroundStyle(.orange)
            .accessibilityLabel("等待回答问题")
        } else if attention == .elicitation {
          Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(.orange)
            .accessibilityLabel("等待完成 MCP 请求")
        } else if let run, run.isActive {
          ProgressView().controlSize(.mini).frame(width: 12)
        } else {
          Image(systemName: task.pinned ? "pin" : "text.bubble").appFont(size: 11)
            .foregroundStyle(.tertiary).frame(width: 12)
        }
        if store.library.unreadTasks.contains(task.id) {
          Circle().fill(.blue).frame(width: 5, height: 5)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(task.title).lineLimit(1).appFont(size: 12)
          if showsProject {
            Text(store.library.projectTitle(task.project)).appFont(size: 10).foregroundStyle(
              .secondary
            ).lineLimit(1)
          }
        }
        Spacer(minLength: 2)
        if run?.status == "failed" { Circle().fill(.orange).frame(width: 5, height: 5) }
      }.padding(.horizontal, 10).padding(.vertical, 9)
        .background(
          store.destination == .workspace && store.selectedTask?.id == task.id
            ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(!store.canSelectTask(task))
      .help("\(task.title) · \(store.library.projectTitle(task.project))")
      .accessibilityAddTraits(
        store.destination == .workspace && store.selectedTask?.id == task.id ? .isSelected : []
      )
      .contextMenu {
        Button("重命名…") { store.beginRenamingTask(task.id) }
        Button(store.library.unreadTasks.contains(task.id) ? "标记为已读" : "标记为未读") {
          store.setTaskUnread(task.id, unread: !store.library.unreadTasks.contains(task.id))
        }
        Button(task.pinned ? "取消置顶" : "置顶任务") { store.updateTask(task.id, pin: !task.pinned) }
        SidebarPlacementMenu(store: store, item: .task(task.id))
        if let pending = store.library.managedWorktrees.first(where: { $0.taskID == task.id })?.pendingHandoff {
          Button("继续移交") {
            Task {
              if pending.direction == .toWorktree { await store.handOffTaskToWorktree(task.id) }
              else { await store.handOffTaskToLocal(task.id) }
            }
          }
          .disabled(!store.canHandOffToWorktree(task) && !store.canHandOffToLocal(task))
        } else if store.library.managedWorktrees.contains(where: {
          $0.taskID == task.id && $0.path == task.project
        }) {
          Button("移交到本地") { Task { await store.handOffTaskToLocal(task.id) } }
            .disabled(!store.canHandOffToLocal(task))
        } else if store.library.projects.contains(task.project),
          !store.library.isPermanentWorktree(task.project) {
          Button("移交到工作树") { Task { await store.handOffTaskToWorktree(task.id) } }
            .disabled(!store.canHandOffToWorktree(task))
        }
        Button(task.archived ? "恢复任务" : "归档任务") {
          store.updateTask(task.id, archive: !task.archived)
        }
        .disabled(store.activeRun(taskID: task.id) != nil || store.managedTaskPreparing ||
          store.library.managedWorktrees.contains(where: {
            $0.taskID == task.id && $0.pendingHandoff != nil
          }))
      }
      .modifier(SidebarItemDrag(store: store, item: .task(task.id)))
  }
}
