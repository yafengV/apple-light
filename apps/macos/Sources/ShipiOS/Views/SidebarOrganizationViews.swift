import SwiftUI

struct SidebarPlacementMenu: View {
  let store: WorkspaceStore
  let item: SidebarItem
  var body: some View {
    Menu("移动到分组") {
      destination("已置顶", id: SidebarLayout.pinned)
      if case .project = item {
        destination("项目", id: SidebarLayout.projects)
      }
      if case .task(let id) = item {
        if let task = store.library.tasks.first(where: { $0.id == id }) {
          destination(
            store.library.projectTitle(task.project), id: SidebarLayout.project(task.project))
        }
      }
      if case .contentTab = item {
      } else {
        ForEach(store.library.sidebar.groups) { destination($0.name, id: $0.id) }
        Divider()
        Button("新建分组…") { store.editSidebarGroup(moving: item) }
      }
    }
    Button("上移") { store.shiftSidebarItem(item, by: -1) }.disabled(
      !store.canShiftSidebarItem(item, by: -1))
    Button("下移") { store.shiftSidebarItem(item, by: 1) }.disabled(
      !store.canShiftSidebarItem(item, by: 1))
  }
  private func destination(_ title: String, id: String) -> some View {
    Button {
      store.moveSidebarItem(item, to: id)
    } label: {
      if store.library.sidebarSection(for: item) == id {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }.disabled(store.library.sidebarSection(for: item) == id)
  }
}

struct SidebarItemDrag: ViewModifier {
  let store: WorkspaceStore
  let item: SidebarItem
  @State private var targeted = false
  func body(content: Content) -> some View {
    content.draggable(item.dragToken)
      .overlay(alignment: .top) {
        if targeted { Rectangle().fill(Color.accentColor).frame(height: 2) }
      }
      .dropDestination(for: String.self) { tokens, _ in
        if case .task(let taskID) = item,
          let tabID = tokens.compactMap(WorkspaceTabDragToken.decode).first {
          Task { await store.moveWorkspaceTab(tabID, toTaskID: taskID) }
          return true
        }
        return store.acceptSidebarItemDrop(tokens, on: item)
      } isTargeted: {
        targeted = $0
        if case .task(let taskID) = item, $0, store.draggingWorkspaceTabID != nil {
          store.workspaceTabDropTarget = .chat(taskID)
        } else if case .task(let taskID) = item,
          store.workspaceTabDropTarget == .chat(taskID) {
          store.workspaceTabDropTarget = nil
        }
      }
      .overlay {
        if case .task(let taskID) = item, store.workspaceTabDropTarget == .chat(taskID) {
          RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
        }
      }
  }
}

struct SidebarGroupEditorView: View {
  @Bindable var store: WorkspaceStore
  let editor: SidebarGroupEditor
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(editor.existingID == nil ? "新建分组" : "重命名分组").appFont(.title2, weight: .semibold)
      TextField("分组名称", text: $store.sidebarGroupDraft).textFieldStyle(.roundedBorder).focused(
        $focused
      )
      .onSubmit { store.saveSidebarGroup(editor) }
      HStack {
        Spacer()
        Button("取消") { store.sidebarGroupEditor = nil }.keyboardShortcut(.cancelAction)
        Button("保存") { store.saveSidebarGroup(editor) }.keyboardShortcut(.defaultAction)
          .disabled(store.sidebarGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 360).onAppear { focused = true }
  }
}

struct SidebarOrganizedSection: View {
  let store: WorkspaceStore
  let id: String
  let title: String
  var group: SidebarGroup?
  @State private var targeted = false
  private var items: [SidebarItem] { store.library.sidebarItems(in: id) }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        if let group {
          Button {
            store.toggleSidebarGroup(group.id)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: group.collapsed ? "chevron.right" : "chevron.down").appFont(size: 9)
              Text(title)
              Spacer()
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel("\(group.collapsed ? "展开" : "收起")分组：\(title)")
            .draggable("shipios-group-v1:" + group.id)
          Menu {
            Button("重命名分组…") { store.editSidebarGroup(group) }
            Button("上移分组") { store.shiftSidebarGroup(group.id, by: -1) }
              .disabled(store.library.sidebar.groups.first?.id == group.id)
            Button("下移分组") { store.shiftSidebarGroup(group.id, by: 1) }
              .disabled(store.library.sidebar.groups.last?.id == group.id)
            Divider()
            Button("删除分组…") { store.sidebarGroupToDelete = group }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("分组菜单：\(title)")
        } else {
          Text(title)
          Spacer()
          if id == SidebarLayout.projects {
            Menu {
              Button("添加项目…") { store.chooseProject() }.disabled(
                store.busy || store.activeLocalRun != nil)
              Button("新建分组…") { store.editSidebarGroup() }
            } label: {
              Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("添加项目或分组")
          }
        }
      }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
          targeted ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6)
        )
        .dropDestination(for: String.self) { values, _ in
          if id == SidebarLayout.pinned,
            let tabID = values.compactMap(WorkspaceTabDragToken.decode).first {
            store.pinWorkspaceTab(tabID)
            store.endWorkspaceTabDrag()
            return true
          }
          return store.acceptSidebarDrop(values, to: id)
        } isTargeted: {
          targeted = $0
          if id == SidebarLayout.pinned, $0, store.draggingWorkspaceTabID != nil {
            store.workspaceTabDropTarget = .pin
          } else if id == SidebarLayout.pinned, store.workspaceTabDropTarget == .pin {
            store.workspaceTabDropTarget = nil
          }
        }
      if group?.collapsed != true {
        ForEach(items) { item in
          switch item {
          case .project(let path): SidebarProjectSection(store: store, path: path)
          case .task(let id):
            if let task = store.library.tasks.first(where: { $0.id == id }) {
              SidebarTaskRow(store: store, task: task, showsProject: id != SidebarLayout.projectless)
            }
          case .contentTab(let pinID):
            if let pin = store.library.pinnedContentTabs.first(where: { $0.id == pinID }) {
              SidebarPinnedContentTabRow(store: store, pin: pin)
            }
          }
        }
        if items.isEmpty {
          Text(
            id == SidebarLayout.pinned
              ? "松开放到已置顶"
              : group == nil
                ? (id == SidebarLayout.projectless ? "暂无任务" : "暂无项目")
                : "将项目或任务拖到分组标题，或使用右键菜单移动。"
          )
            .appFont(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(
              .vertical, 6)
        }
      }
    }
  }
}

private struct SidebarPinnedContentTabRow: View {
  let store: WorkspaceStore
  let pin: PinnedWorkspaceTab

  var body: some View {
    Button {
      Task { await store.openPinnedWorkspaceTab(pin.id) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: pin.kind == .browser ? "globe" : "square.stack.3d.up")
          .appFont(size: 11).foregroundStyle(.tertiary).frame(width: 12)
        VStack(alignment: .leading, spacing: 3) {
          Text(store.pinnedWorkspaceTabTitle(pin)).lineLimit(1).appFont(size: 12)
          Text(store.pinnedWorkspaceTabIsLive(pin) ? "内容标签" : "可恢复的内容标签")
            .appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 2)
      }
      .padding(.horizontal, 10).padding(.vertical, 9)
      .background(
        store.destination == .workspace && store.focusedWorkspaceTabID == pin.sourceTabID
          ? Color.primary.opacity(0.09) : .clear,
        in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(store.pinnedWorkspaceTabTitle(pin))
    .accessibilityLabel("固定标签：\(store.pinnedWorkspaceTabTitle(pin))")
    .accessibilityAddTraits(
      store.destination == .workspace && store.focusedWorkspaceTabID == pin.sourceTabID
        ? .isSelected : [])
    .contextMenu {
      Button("打开") { Task { await store.openPinnedWorkspaceTab(pin.id) } }
      Button("从侧栏取消固定") { store.unpinWorkspaceTab(pin.id) }
    }
    .modifier(SidebarItemDrag(store: store, item: .contentTab(pin.id)))
  }
}
