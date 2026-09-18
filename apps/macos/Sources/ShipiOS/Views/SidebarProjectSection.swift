import SwiftUI

struct SidebarProjectSection: View {
  let store: WorkspaceStore
  let path: String
  private var expanded: Bool { !store.library.collapsedProjects.contains(path) }
  private var tasks: [WorkspaceTask] {
    store.library.sidebarItems(in: SidebarLayout.project(path)).compactMap { item in
      guard case .task(let id) = item else { return nil }
      return store.library.tasks.first { $0.id == id }
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 2) {
        Button {
          withAnimation { store.toggleProjectExpansion(path) }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").appFont(
              size: 9, weight: .semibold)
            Image(systemName: store.library.pinnedProjects.contains(path) ? "pin"
              : store.library.isPermanentWorktree(path) ? "arrow.triangle.branch" : "folder")
            Text(store.library.projectTitle(path)).lineLimit(1)
            Spacer(minLength: 0)
          }.appFont(size: 12, weight: .medium).padding(.vertical, 9).padding(.leading, 9)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(path)
          .accessibilityLabel("\(expanded ? "收起" : "展开")项目：\(store.library.projectTitle(path))")
          .accessibilityValue(expanded ? "已展开" : "已收起")
        Menu {
          ProjectActionsMenu(store: store, path: path)
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 5)
        .accessibilityLabel("项目菜单：\(store.library.projectTitle(path))")
      }.contextMenu { ProjectActionsMenu(store: store, path: path) }
        .modifier(SidebarItemDrag(store: store, item: .project(path)))
      if expanded {
        ForEach(tasks) { SidebarTaskRow(store: store, task: $0) }
        if tasks.isEmpty {
          Button("新建任务") { Task { await store.newTask(in: path) } }
            .buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
            .padding(.leading, 30).padding(.vertical, 8)
            .disabled(store.busy || (store.project?.path != path && store.activeLocalRun != nil))
            .accessibilityLabel("在\(store.library.projectTitle(path))中新建任务")
        }
      }
    }
  }
}

struct ProjectActionsMenu: View {
  let store: WorkspaceStore
  let path: String
  var body: some View {
    Button("新建任务") { Task { await store.newTask(in: path) } }
      .disabled(store.busy || (store.project?.path != path && store.activeLocalRun != nil))
    Button("打开项目") { Task { await store.open(URL(fileURLWithPath: path)) } }
      .disabled(store.busy || store.activeLocalRun != nil)
    Button("创建永久工作树…") { store.beginWorktreeCreation(from: path) }
      .disabled(store.busy || store.activeLocalRun != nil)
    Divider()
    Button(store.library.pinnedProjects.contains(path) ? "取消置顶项目" : "置顶项目") {
      store.toggleProjectPin(path)
    }
    Button("重命名项目…") { store.beginRenamingProject(path) }
    SidebarPlacementMenu(store: store, item: .project(path))
    Button("归档项目内的任务") { store.archiveProject(path) }
      .disabled(!store.library.tasks.contains { $0.project == path && !$0.archived })
    Divider()
    Button("在 Finder 中显示") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
  }
}
