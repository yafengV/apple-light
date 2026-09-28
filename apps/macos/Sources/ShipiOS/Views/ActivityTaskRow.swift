import SwiftUI

struct ActivityTaskRow: View {
  let store: WorkspaceStore
  let item: ActivityTaskEntry
  let opening: Bool
  let openingAny: Bool
  let focused: Bool
  let open: () -> Void
  @State private var hovered = false
  private enum Action: Hashable { case pin, archive }
  @FocusState private var focusedAction: Action?
  private var showsActions: Bool { hovered || focused || focusedAction != nil }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.task.title.isEmpty ? "未命名任务" : item.task.title)
            .appFont(.callout, weight: item.unread ? .semibold : .regular).lineLimit(1)
          Text(item.task.project.isEmpty ? item.statusTitle
            : store.library.projectTitle(item.task.project) + " · " + item.statusTitle)
            .appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(openingAny || !store.canSelectTask(item.task))
        .accessibilityLabel("\(item.task.title)，\(item.statusTitle)")
        .accessibilityAddTraits(store.selectedTask?.id == item.id ? .isSelected : [])
      ZStack(alignment: .trailing) {
        status.opacity(showsActions ? 0 : 1).accessibilityHidden(showsActions)
        HStack(spacing: 7) {
          Button { store.toggleTaskPinFromMenu(item.id) } label: {
            Image(systemName: item.task.pinned ? "pin.slash" : "pin")
          }.help(item.task.pinned ? "取消置顶" : "置顶任务")
            .focused($focusedAction, equals: .pin)
            .accessibilityLabel(item.task.pinned ? "取消置顶：\(item.task.title)" : "置顶：\(item.task.title)")
            .disabled(store.taskMenuTarget(item.id) == nil)
          Button { Task { await store.archiveActivityTask(item.id) } } label: {
            Image(systemName: "archivebox")
          }.help("归档任务").accessibilityLabel("归档：\(item.task.title)")
            .focused($focusedAction, equals: .archive)
            .disabled(!store.canArchiveActivityTask(item.id))
        }.buttonStyle(.plain).appFont(size: 11).foregroundStyle(.secondary)
          .opacity(showsActions ? 1 : 0)
          .allowsHitTesting(showsActions).accessibilityHidden(!showsActions)
      }.frame(width: 37).padding(.leading, 6)
    }.padding(.horizontal, 10)
      .background(focused || store.selectedTask?.id == item.id || hovered
        ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle()).onHover { hovered = $0 }
      .contextMenu { SidebarTaskMenu(store: store, taskID: item.id, activity: true) }
      .accessibilityIdentifier("activity-task-\(item.id)")
  }

  @ViewBuilder private var status: some View {
    if opening || item.running && item.attention == nil {
      ProgressView().controlSize(.mini).frame(width: 16)
    } else if item.unread && item.attention == nil {
      Circle().fill(.blue).frame(width: 5, height: 5)
    } else {
      Image(systemName: item.statusIcon).appFont(size: 11)
        .foregroundStyle(item.attention != nil ? .orange : .secondary)
    }
  }
}
