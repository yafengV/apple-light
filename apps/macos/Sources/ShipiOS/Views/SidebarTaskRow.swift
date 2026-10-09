import SwiftUI

struct SidebarTaskRow: View {
  let store: WorkspaceStore
  let task: WorkspaceTask
  var showsProject = false
  @Environment(\.sidebarShortcutHintLabels) private var shortcutHints
  @State private var hovered = false
  @FocusState private var focusedAction: SidebarTaskRowAction?
  @FocusState private var primaryFocused: Bool
  private var showsActions: Bool { hovered || primaryFocused || focusedAction != nil }
  private var selected: Bool {
    store.destination == .workspace && (store.worktreeForkPresentation.preparation.map {
      $0.taskID == task.id
    } ?? (store.selectedTask?.id == task.id))
  }
  private var run: AgentRun? {
    task.runIDs.last.flatMap { id in
      store.runs.first { $0.id == id } ?? store.library.localRuns.first { $0.id == id }
    }
  }
  var body: some View {
    let attention = store.taskAttentionKind(for: task)
    HStack(spacing: 6) {
      Button {
        if let current = store.library.tasks.first(where: { $0.id == task.id }), !current.archived {
          store.selectTask(current)
        }
      } label: {
        HStack(spacing: 8) {
          if store.activeWorktreeForkPreparation?.taskID == task.id {
            ProgressView().controlSize(.mini).frame(width: 12)
          } else if attention == .approval {
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
            Text(task.title.isEmpty ? "未命名任务" : task.title).lineLimit(1).appFont(size: 12)
              .contentShape(Rectangle())
              .simultaneousGesture(TapGesture(count: 2).onEnded {
                store.renameTaskFromRowTitle(task.id)
              })
            if showsProject {
              Text(store.library.projectTitle(task.project)).appFont(size: 10).foregroundStyle(
                .secondary
              ).lineLimit(1)
            }
          }
          Spacer(minLength: 2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
        .contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(!store.canSelectTask(task)).focused($primaryFocused)
        .accessibilityAddTraits(
          selected ? .isSelected : []
        )
      ZStack(alignment: .trailing) {
        HStack(spacing: 6) {
          if let label = shortcutHints[task.id] {
            Text(label).appFont(size: 10, design: .monospaced).foregroundStyle(.secondary)
              .fixedSize().accessibilityLabel("快捷键 \(label)")
              .accessibilityIdentifier("sidebar-task-shortcut-\(task.id)")
          }
          if run?.status == "failed" { Circle().fill(.orange).frame(width: 5, height: 5) }
        }.opacity(showsActions ? 0 : 1).accessibilityHidden(showsActions)
        SidebarTaskRowActions(store: store, taskID: task.id, focus: $focusedAction)
          .opacity(showsActions ? 1 : 0)
          .allowsHitTesting(showsActions).accessibilityHidden(!showsActions)
      }.frame(minWidth: 52).fixedSize(horizontal: true, vertical: false)
    }.padding(.horizontal, 10)
      .background(
        selected || hovered || primaryFocused || focusedAction != nil
          ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7)
      )
      .contentShape(Rectangle()).onHover { hovered = $0 }
      .accessibilityIdentifier("sidebar-task-\(task.id)")
      .help("\(task.title) · \(store.library.projectTitle(task.project))")
      .contextMenu { SidebarTaskMenu(store: store, taskID: task.id) }
      .modifier(SidebarItemDrag(store: store, item: .task(task.id)))
  }
}
