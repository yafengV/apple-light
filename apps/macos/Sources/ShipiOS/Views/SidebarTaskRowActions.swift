import SwiftUI

enum SidebarTaskRowAction: Hashable { case pin, archive }

/// Peer buttons preserve the current conversation and resolve the latest row identity.
struct SidebarTaskRowActions: View {
  let store: WorkspaceStore
  let taskID: String
  var activity = false
  let focus: FocusState<SidebarTaskRowAction?>.Binding

  var body: some View {
    if let task = store.library.tasks.first(where: { $0.id == taskID }) {
      HStack(spacing: 8) {
        Button { store.toggleTaskPinFromMenu(taskID) } label: {
          Image(systemName: task.pinned ? "pin.slash" : "pin")
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }.help(task.pinned ? "取消置顶" : "置顶任务")
          .focused(focus, equals: .pin)
          .accessibilityLabel(task.pinned ? "取消置顶：\(task.title)" : "置顶：\(task.title)")
          .accessibilityIdentifier("sidebar-task-pin-\(taskID)")
        Button {
          Task {
            if activity { await store.archiveActivityTask(taskID) }
            else { await store.archiveTask(taskID) }
          }
        } label: {
          Image(systemName: "archivebox").frame(width: 20, height: 20).contentShape(Rectangle())
        }
          .help("归档任务").accessibilityLabel("归档：\(task.title)")
          .accessibilityIdentifier("sidebar-task-archive-\(taskID)")
          .focused(focus, equals: .archive)
          .disabled(activity ? !store.canArchiveActivityTask(taskID) : !store.canArchiveTask(taskID))
      }.buttonStyle(.plain).appFont(size: 16).foregroundStyle(.secondary)
        .disabled(task.archived || store.taskMenuTarget(taskID) == nil)
    }
  }
}
