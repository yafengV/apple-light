import SwiftUI

struct TaskSidebarView: View {
  @Bindable var store: WorkspaceStore
  @State private var shortcutHints = SidebarShortcutHintController()
  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        regularSidebar
          .opacity(store.showingActivity ? 0 : 1)
          .allowsHitTesting(!store.showingActivity)
          .disabled(store.showingActivity)
          .accessibilityHidden(store.showingActivity)
        if store.showingActivity { ActivityView(store: store) }
      }.frame(minHeight: 0, maxHeight: .infinity)
      profileFooter
    }
    .environment(\.sidebarShortcutHintLabels, shortcutHints.labels)
    .background {
      SidebarShortcutHintBridge(context: store.sidebarShortcutHintContext, controller: shortcutHints)
        .frame(width: 0, height: 0).allowsHitTesting(false)
    }
    .sheet(item: $store.sidebarGroupEditor) { editor in
      SidebarGroupEditorView(store: store, editor: editor)
    }
    .alert("删除分组？", isPresented: Binding(
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

  private var regularSidebar: some View {
    VStack(spacing: 0) {
      VStack(spacing: 2) {
        HStack(spacing: 12) {
          Menu {
            Button("项目", systemImage: "folder") { store.showProjects() }
            Button("插件", systemImage: "shippingbox") { store.showPlugins() }
            Button("技能", systemImage: "wand.and.stars") { store.showSkills() }
            Button("自动化", systemImage: "clock.arrow.circlepath") { store.showAutomations() }
            Divider()
            Button("命令菜单", systemImage: "command") { store.showingCommands = true }
          } label: {
            Text("ShipiOS").appFont(size: 17, weight: .semibold)
          }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("工作区导航")
          Spacer(minLength: 0)
          Button { store.toggleActivity() } label: {
            Image(systemName: store.activityBadgeCount > 0 ? "bell.badge" : "bell")
          }.buttonStyle(.plain).disabled(!store.libraryLoaded)
            .accessibilityLabel("活动")
            .accessibilityValue(store.activityBadgeCount > 0 ? "\(store.activityBadgeCount) 项需关注" : "")
            .help("活动 \(store.shortcuts.label("activity"))")
          Button { store.showingSearch = true } label: {
            Image(systemName: "magnifyingglass")
          }.buttonStyle(.plain).accessibilityLabel("搜索任务")
            .help("搜索任务 \(store.shortcuts.label("search"))")
        }.padding(.horizontal, 10).padding(.bottom, 12)
        navButton("新任务", "square.and.pencil", shortcut: store.shortcuts.label("new")) {
          Task { await store.newChat() }
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
      }.padding(.horizontal, 10).padding(.top, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let preparation = store.activeWorktreeForkPreparation,
            let id = preparation.taskID, !store.library.tasks.contains(where: { $0.id == id }) {
            Button {
              store.destination = .workspace
              store.worktreeForkPresentation.present(preparation)
            } label: {
              HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(preparation.title).lineLimit(1).appFont(size: 12)
                Spacer(minLength: 0)
              }.padding(10)
            }.buttonStyle(.plain).accessibilityIdentifier("sidebar-pending-worktree-fork")
          }
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
    }
  }

  private var profileFooter: some View {
    VStack(spacing: 12) {
      if !store.connected, let project = store.project {
        Button("重新连接 Agent", systemImage: "arrow.clockwise") {
          Task { await store.open(project) }
        }.disabled(store.busy)
      }
      SidebarProfileMenu(store: store)
    }.padding(16)
  }
  private func navButton(
    _ title: String, _ icon: String, shortcut: String = "", selected: Bool = false, badge: Int = 0,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon).frame(width: 16)
        Text(title)
        Spacer()
        if badge > 0 {
          Text(badge.formatted())
            .appFont(size: 10, weight: .semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .accessibilityLabel("\(badge) 项需关注")
        }
        Text(shortcut).appFont(.caption).foregroundStyle(.tertiary)
      }.padding(.horizontal, 10).padding(.vertical, 9)
        .background(
          selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityValue(badge > 0 ? "\(badge) 项需关注" : "")
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
