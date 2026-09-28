import SwiftUI

struct ActivityTaskRow: View {
  let store: WorkspaceStore
  let item: ActivityTaskEntry
  let opening: Bool
  let openingAny: Bool
  let focused: Bool
  let open: () -> Void
  @State private var hovered = false
  @FocusState private var focusedAction: SidebarTaskRowAction?
  @FocusState private var primaryFocused: Bool
  private var showsActions: Bool { hovered || focused || primaryFocused || focusedAction != nil }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.task.title.isEmpty ? "未命名任务" : item.task.title)
            .appFont(.callout, weight: item.unread ? .semibold : .regular).lineLimit(1)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded {
              store.renameTaskFromRowTitle(item.id)
            })
          Text(item.task.project.isEmpty ? item.statusTitle
            : store.library.projectTitle(item.task.project) + " · " + item.statusTitle)
            .appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(openingAny || !store.canSelectTask(item.task))
        .focused($primaryFocused)
        .accessibilityLabel("\(item.task.title)，\(item.statusTitle)")
        .accessibilityAddTraits(store.selectedTask?.id == item.id ? .isSelected : [])
      ZStack(alignment: .trailing) {
        status.opacity(showsActions ? 0 : 1).accessibilityHidden(showsActions)
        SidebarTaskRowActions(store: store, taskID: item.id, activity: true, focus: $focusedAction)
          .opacity(showsActions ? 1 : 0)
          .allowsHitTesting(showsActions).accessibilityHidden(!showsActions)
      }.frame(width: 52).padding(.leading, 6)
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
