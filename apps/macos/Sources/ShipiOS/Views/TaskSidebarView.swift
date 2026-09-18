import SwiftUI

struct TaskSidebarView: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        navButton("新任务", "square.and.pencil", shortcut: store.shortcuts.label("new")) {
          Task { await store.newProjectlessTask() }
        }
        .disabled(!store.commandEnabled("new"))
        .overlay {
          if store.workspaceTabDropTarget == .newChat {
            RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2)
              .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
              .allowsHitTesting(false)
          }
        }
        .dropDestination(for: String.self) { values, _ in
          guard let id = values.compactMap(WorkspaceTabDragToken.decode).first else {
            return false
          }
          Task { await store.moveWorkspaceTabToNewTask(id) }
          return true
        } isTargeted: { targeted in
          if targeted, store.draggingWorkspaceTabID != nil {
            store.workspaceTabDropTarget = .newChat
          } else if store.workspaceTabDropTarget == .newChat {
            store.workspaceTabDropTarget = nil
          }
        }
        navButton("搜索任务", "magnifyingglass", shortcut: store.shortcuts.label("search")) {
          store.showingSearch = true
        }
        navButton("项目", "folder", selected: store.destination == .projects) { store.showProjects() }
        navButton("插件", "shippingbox", selected: store.destination == .plugins || store.destination == .pluginDetail) { store.showPlugins() }
        navButton("自动化", "clock.arrow.circlepath", selected: store.destination == .automations) {
          store.showAutomations()
        }
        navButton("命令菜单", "command", shortcut: store.shortcuts.label("palette")) {
          store.showingCommands = true
        }
      }.padding(.horizontal, 10).padding(.top, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if !store.library.sidebarItems(in: SidebarLayout.pinned).isEmpty
            || store.draggingWorkspaceTabID != nil {
            SidebarOrganizedSection(store: store, id: SidebarLayout.pinned, title: "已置顶")
          }
          ForEach(store.library.sidebar.groups) { group in
            SidebarOrganizedSection(store: store, id: group.id, title: group.name, group: group)
          }
          SidebarOrganizedSection(store: store, id: SidebarLayout.projects, title: "项目")
          SidebarOrganizedSection(store: store, id: SidebarLayout.projectless, title: "任务")
        }.padding(.horizontal, 10).padding(.top, 22)
      }.frame(minHeight: 0, maxHeight: .infinity)
      VStack(spacing: 12) {
        if !store.connected, let project = store.project {
          Button("重新连接 Agent", systemImage: "arrow.clockwise") {
            Task { await store.open(project) }
          }
          .disabled(store.busy)
        }
        SidebarProfileMenu(store: store)
      }.padding(16)
    }
    .sheet(item: $store.sidebarGroupEditor) { editor in
      SidebarGroupEditorView(store: store, editor: editor)
    }
    .alert(
      "删除分组？",
      isPresented: Binding(
        get: { store.sidebarGroupToDelete != nil },
        set: { if !$0 { store.sidebarGroupToDelete = nil } })
    ) {
      Button("取消", role: .cancel) { store.sidebarGroupToDelete = nil }
      Button("删除分组") {
        if let group = store.sidebarGroupToDelete { store.deleteSidebarGroup(group.id) }
      }
    } message: {
      Text("只删除分组，项目和任务会回到原来的列表，不会删除会话或文件。")
    }
  }
  private func navButton(
    _ title: String, _ icon: String, shortcut: String = "", selected: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 16)
        Text(title)
        Spacer()
        Text(shortcut).appFont(.caption).foregroundStyle(.tertiary)
      }.padding(.horizontal, 10).padding(.vertical, 9)
        .background(
          selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

private struct SidebarProfileMenu: View {
  let store: WorkspaceStore

  var body: some View {
    Menu {
      Button("个人资料", systemImage: "person.crop.circle") {
        store.openSettings(.profile)
      }
      Button("设置", systemImage: "gearshape") { store.openSettings(.general) }
        .keyboardShortcut(",", modifiers: .command)
      Divider()
      Button("模型与 API", systemImage: "cpu") { store.openSettings(.model) }
      Button("用量", systemImage: "chart.bar.xaxis") { store.openSettings(.usage) }
      Button("已归档任务", systemImage: "archivebox") { store.openSettings(.archived) }
      Divider()
      Button("打开独立数据目录", systemImage: "folder") {
        NSWorkspace.shared.open(store.dataRoot)
      }
    } label: {
      HStack(spacing: 10) {
        avatar
        VStack(alignment: .leading, spacing: 2) {
          Text(displayName).appFont(size: 12, weight: .medium).lineLimit(1)
          HStack(spacing: 5) {
            Circle().fill(store.connected ? Color.green : Color.secondary)
              .frame(width: 6, height: 6)
            Text(connectionLabel).appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 2)
        Image(systemName: "chevron.up.chevron.down").appFont(size: 9)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 9).padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .help("账户与设置 \(store.shortcuts.label("settings"))")
    .accessibilityLabel("账户与设置")
  }

  private var displayName: String {
    store.profile.displayName.isEmpty ? "ShipiOS" : store.profile.displayName
  }

  private var connectionLabel: String {
    store.project == nil ? "独立 API" : store.connected ? "本地工作区" : "未连接"
  }

  @ViewBuilder private var avatar: some View {
    if let image = store.profileAvatar {
      Image(nsImage: image).resizable().scaledToFill().frame(width: 26, height: 26)
        .clipShape(Circle()).id(store.profileAvatarVersion)
    } else {
      Text(store.profile.initials).appFont(size: 10, weight: .semibold).foregroundStyle(.white)
        .frame(width: 26, height: 26).background(.blue.gradient, in: Circle())
    }
  }
}
