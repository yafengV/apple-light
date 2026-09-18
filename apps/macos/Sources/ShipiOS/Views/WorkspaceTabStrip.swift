import SwiftUI

struct WorkspaceTabStrip: View {
  @Bindable var store: WorkspaceStore
  var placement: WorkspaceTabPlacement = .left
  var includesChat = true
  @State private var showingNewTabLauncher = false

  var body: some View {
    HStack(spacing: 4) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 2) {
            if includesChat { leadingTab.id("workspace-chat-tab") }
            ForEach(store.visibleWorkspaceContentTabs(in: placement)) { tab in
              WorkspaceContentTabChip(store: store, tab: tab, placement: placement).id(tab.id)
            }
          }.padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .onChange(of: activeID) { _, id in
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(id ?? "workspace-chat-tab", anchor: .center)
          }
        }
      }
      Button { showingNewTabLauncher.toggle() } label: { Image(systemName: "plus") }
        .buttonStyle(.plain).padding(8)
        .help(placement == .bottom ? "打开底部面板标签" : "新标签页")
        .accessibilityLabel(placement == .bottom ? "打开底部面板标签" : "新标签页")
        .popover(isPresented: $showingNewTabLauncher, arrowEdge: .bottom) {
          WorkspaceNewTabLauncher(
            store: store, placement: placement,
            dismiss: { showingNewTabLauncher = false })
        }
    }
    .frame(height: 38)
    .appFont(.caption)
    .background(Color.primary.opacity(0.025))
  }

  private var activeID: String? {
    switch placement {
    case .right: store.activeRightWorkspaceTabID
    case .bottom: store.activeBottomWorkspaceTabID
    default: store.activeWorkspaceTabID
    }
  }

  private var leadingTab: some View {
    Button { store.activateChatTab() } label: {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.bubble.right")
        Text(store.selectedTask?.title ?? "新任务").lineLimit(1).frame(maxWidth: 180)
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(
        store.activeWorkspaceContentTab == nil ? Color.primary.opacity(0.09) : .clear,
        in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .help(store.selectedTask?.title ?? "新任务")
    .accessibilityLabel("聊天标签：\(store.selectedTask?.title ?? "新任务")")
    .accessibilityAddTraits(store.activeWorkspaceContentTab == nil ? .isSelected : [])
    .contextMenu {
      Button("关闭其他标签页") { store.closeOtherWorkspaceTabs(keeping: nil) }
        .disabled(store.visibleWorkspaceContentTabs.isEmpty)
      Button("关闭右侧标签页") { store.closeWorkspaceTabsToRight(of: nil) }
        .disabled(!store.canCloseWorkspaceTabsToRight(of: nil))
    }
  }
}

private struct WorkspaceNewTabLauncher: View {
  @Bindable var store: WorkspaceStore
  let placement: WorkspaceTabPlacement
  let dismiss: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if placement == .bottom {
          launcherSection("终端") {
            launcherButton("打开底部终端", icon: "terminal") {
              store.newTerminalTab(in: .bottom)
            }
            launcherButton("终端选项", icon: "slider.horizontal.3") {
              store.openSettings(.runtime)
            }
          }
        } else {
          launcherSection("推荐") {
            launcherButton("浏览器", icon: "globe") { store.newBrowserTab(in: placement) }
            if store.project != nil {
              launcherButton("审查", icon: "square.stack.3d.up") {
                store.openReviewTab(in: placement)
              }
              launcherButton("打开底部终端", icon: "terminal") {
                store.newTerminalTab(in: .bottom)
              }
            }
          }
          launcherSection("最近工作") {
            if store.canReopenClosedWorkspaceTab {
              launcherButton("重新打开关闭的标签页", icon: "arrow.uturn.backward") {
                store.reopenClosedWorkspaceTab()
              }
            } else {
              Text("暂无最近关闭的标签页").foregroundStyle(.secondary).appFont(.caption)
                .padding(.horizontal, 8)
            }
          }
          launcherSection("插件和 MCP") {
            let plugins = store.pluginPreferences.installed.filter(\.enabled)
            if plugins.isEmpty {
              launcherButton("浏览插件", icon: "shippingbox") { store.showPlugins() }
            } else {
              ForEach(plugins.prefix(4)) { plugin in
                launcherButton(plugin.name, icon: "shippingbox") { store.showPlugins() }
              }
              if plugins.count > 4 {
                launcherButton("显示全部", icon: "ellipsis") { store.showPlugins() }
              }
            }
          }
          launcherSection("更多工具") {
            if store.project != nil {
              launcherButton("文件", icon: "doc.text.magnifyingglass") {
                store.executeCommand("files")
              }
            }
            launcherButton("自动化", icon: "clock.arrow.circlepath") {
              store.showAutomations()
            }
          }
        }
      }
      .padding(16)
    }
    .frame(width: 320, height: placement == .bottom ? 150 : 430)
    .accessibilityLabel(placement == .bottom ? "打开底部面板标签" : "新标签页")
  }

  private func launcherSection<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 8)
      content()
    }
  }

  private func launcherButton(
    _ title: String, icon: String, action: @escaping () -> Void
  ) -> some View {
    Button {
      dismiss()
      action()
    } label: {
      Label(title, systemImage: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct WorkspaceContentTabChip: View {
  @Bindable var store: WorkspaceStore
  let tab: WorkspaceContentTab
  let placement: WorkspaceTabPlacement
  @State private var chipWidth: CGFloat = 0
  @State private var dropTargeted = false

  var body: some View {
    HStack(spacing: 5) {
      Button { store.activateWorkspaceTab(tab.id) } label: {
        HStack(spacing: 6) {
          Image(systemName: tab.icon)
          Text(store.workspaceTabTitle(tab)).lineLimit(1).frame(maxWidth: 150)
        }
      }.buttonStyle(.plain).help(store.workspaceTabTitle(tab))
      Button { store.closeWorkspaceTab(tab.id) } label: {
        Image(systemName: "xmark").appFont(size: 9)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("关闭标签：\(store.workspaceTabTitle(tab))")
    }
    .padding(.horizontal, 9).padding(.vertical, 7)
    .background(
      activeID == tab.id ? Color.primary.opacity(0.09) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { chipWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in chipWidth = width }
      }
    }
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(activeID == tab.id ? .isSelected : [])
    .onDrag {
      store.beginWorkspaceTabDrag(tab.id)
      return NSItemProvider(object: WorkspaceTabDragToken.encode(tab.id) as NSString)
    }
    .dropDestination(for: String.self) { values, location in
      defer {
        dropTargeted = false
        store.endWorkspaceTabDrag()
      }
      guard let source = values.compactMap(WorkspaceTabDragToken.decode).first,
        source != tab.id,
        store.workspaceTabPlacement(source) == placement else { return false }
      return store.reorderWorkspaceTab(source, relativeTo: tab.id, after: location.x > chipWidth / 2)
    } isTargeted: { targeted in
      dropTargeted = targeted
    }
    .contextMenu {
      Button(store.isWorkspaceTabPinned(tab.id) ? "从侧栏取消固定" : "固定到侧栏") {
        if store.isWorkspaceTabPinned(tab.id) { store.unpinWorkspaceTab(tab.id) }
        else { store.pinWorkspaceTab(tab.id) }
      }
      Divider()
      if placement != .left {
        Button("移到主内容区") { store.moveWorkspaceTab(tab.id, to: .left) }
      }
      if placement != .right {
        Button("移到右侧面板") { store.moveWorkspaceTab(tab.id, to: .right) }
      }
      if tab.terminalID != nil, placement != .bottom {
        Button("移到底部面板") { store.moveWorkspaceTab(tab.id, to: .bottom) }
      }
      Divider()
      Button("关闭") { store.closeWorkspaceTab(tab.id) }
      Button("关闭其他标签页") { store.closeOtherWorkspaceTabs(keeping: tab.id) }
        .disabled(store.visibleWorkspaceContentTabs.count <= 1)
      Button("关闭右侧标签页") { store.closeWorkspaceTabsToRight(of: tab.id) }
        .disabled(!store.canCloseWorkspaceTabsToRight(of: tab.id))
    }
  }


  private var activeID: String? {
    switch placement {
    case .right: store.activeRightWorkspaceTabID
    case .bottom: store.activeBottomWorkspaceTabID
    default: store.activeWorkspaceTabID
    }
  }
}

extension View {
  func workspaceTabDropDestination(
    store: WorkspaceStore, placement: WorkspaceTabPlacement
  ) -> some View {
    dropDestination(for: String.self) { values, _ in
      defer {
        store.endWorkspaceTabDrag()
      }
      guard let id = values.compactMap(WorkspaceTabDragToken.decode).first,
        store.canMoveWorkspaceTab(id, to: placement) else { return false }
      store.moveWorkspaceTab(id, to: placement)
      return true
    } isTargeted: { targeted in
      if targeted {
        if let id = store.draggingWorkspaceTabID,
          store.canMoveWorkspaceTab(id, to: placement) {
          store.workspaceTabDropTarget = .placement(placement)
        }
      } else if store.workspaceTabDropTarget == .placement(placement) {
        store.workspaceTabDropTarget = nil
      }
    }
    .overlay {
      if store.workspaceTabDropTarget == .placement(placement) {
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
          .padding(5)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }
}
