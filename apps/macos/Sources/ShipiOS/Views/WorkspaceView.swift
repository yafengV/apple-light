import SwiftUI

struct WorkspaceView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.openWindow) private var openWindow
  @State private var renameHistory = TaskRenameHistory()
  @State private var columns: NavigationSplitViewVisibility = .all

  var body: some View {
    GeometryReader { geometry in
      NavigationSplitView(columnVisibility: $columns) {
        TaskSidebarView(store: store)
          .appSidebarSurface()
          .toolbar(removing: store.destination == .settings ? .sidebarToggle : nil)
          .frame(height: geometry.size.height)
          .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 310)
      } detail: {
        GeometryReader { detail in
          let inspectorWidth = store.panelSizes.inspector(available: detail.size.width)
          let terminalHeight = store.panelSizes.terminal(available: detail.size.height)
          HStack(spacing: 0) {
            if store.showingInspector && store.workspaceContentPaneSide == .left {
              inspectorColumn(width: inspectorWidth, height: detail.size.height)
              inspectorResizeHandle(availableWidth: detail.size.width)
            }
            mainWorkspaceColumn(
              width: max(
                0,
                detail.size.width
                  - (store.showingInspector ? inspectorWidth + WorkspacePanelSizes.divider : 0)),
              height: detail.size.height, terminalHeight: terminalHeight)
            if store.showingInspector && store.workspaceContentPaneSide == .right {
              inspectorResizeHandle(availableWidth: detail.size.width)
              inspectorColumn(width: inspectorWidth, height: detail.size.height)
            }
          }.frame(width: detail.size.width, height: detail.size.height)
            .appSurface()
            .opacity(store.retainsStandalonePage ? 0 : 1)
            .allowsHitTesting(!store.retainsStandalonePage)
            .disabled(store.retainsStandalonePage)
            .accessibilityHidden(store.retainsStandalonePage)
            .overlay {
              ZStack {
                Group {
                  if store.retainsProjectsPage { ProjectLibraryView(store: store) }
                  else if store.retainsPluginsPage { PluginsView(store: store) }
                  else if store.retainsAutomationsPage { AutomationsView(store: store) }
                }
                .opacity(store.destination == .pluginDetail ? 0 : 1)
                .allowsHitTesting(store.destination != .pluginDetail)
                .disabled(store.destination == .pluginDetail)
                .accessibilityHidden(store.destination == .pluginDetail)
                if store.destination == .pluginDetail { PluginDetailView(store: store) }
              }
            }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .navigationTitle(
        store.destination == .settings
          ? "设置"
          : store.destination == .pluginDetail
            ? store.currentPluginDetail?.name ?? "插件详情"
          : store.destination == .projects
            ? "项目"
            : store.destination == .plugins
              ? "插件"
              : store.destination == .automations ? "自动化" : store.selectedTask?.title ?? "新任务"
      )
      .toolbar {
        if store.destination == .workspace {
          ToolbarItem(placement: .navigation) {
            Menu {
              Button("无项目新任务") { Task { await store.newProjectlessTask() } }
              Divider()
              Button("打开项目…") { store.chooseProject() }
              Button("打开示例项目") { Task { await store.openDemo() } }
              Divider()
              ForEach(store.library.orderedProjects, id: \.self) { path in
                Button(store.library.projectTitle(path)) {
                  Task { await store.open(URL(fileURLWithPath: path)) }
                }
              }
            } label: {
              Label(
                store.project.map { store.library.projectTitle($0.path) } ?? "无项目",
                systemImage: "folder")
            }
            .disabled(store.busy || store.activeLocalRun != nil)
          }
          ToolbarItemGroup(placement: .primaryAction) {
            if let project = store.project, store.workspace.gitAvailable {
              Button { store.openBranchPicker() } label: {
                Label(store.workspace.gitBranch, systemImage: "arrow.triangle.branch")
                  .lineLimit(1)
              }
              .help("切换或创建分支")
              .disabled(!store.canChangeBranch)
              .popover(isPresented: $store.showingBranchPicker, arrowEdge: .bottom) {
                GitBranchPicker(store: store, root: project)
              }
            }
            if let project = store.project {
              Button {
                NSWorkspace.shared.open(project)
              } label: {
                Image(systemName: "folder")
              }.help("在 Finder 中打开项目")
            }
            Button {
              store.executeCommand("terminal")
            } label: {
              Image(systemName: "terminal")
            }.help("终端 \(store.shortcuts.label("terminal"))").disabled(!store.commandEnabled("terminal"))
            Button {
              store.executeCommand("review")
            } label: {
              Image(systemName: "square.stack.3d.up")
            }.help("审查 \(store.shortcuts.label("review"))").disabled(!store.commandEnabled("review"))
            Button {
              store.showingInspector.toggle()
            } label: {
              Image(systemName: "sidebar.right")
            }
            .help("显示或隐藏右侧面板").accessibilityLabel("切换详情面板")
            if store.showBottomPanelControl {
              Menu {
                Button(store.showingWorkspaceTabs ? "隐藏标签页" : "显示标签页") {
                  store.toggleWorkspaceTabVisibility()
                }
                Button(store.activeWorkspaceContentTab == nil ? "打开完整视图" : "退出完整视图") {
                  store.toggleWorkspaceTabView()
                }
                Divider()
                Button("交换左侧和右侧面板") { store.swapWorkspacePanes() }
                  .disabled(!store.showingInspector)
              } label: {
                Image(systemName: "rectangle.split.2x1")
              }
              .help("布局")
              .accessibilityLabel("任务布局")
            }
            Menu {
              Button("在新窗口中新建任务") {
                if let task = store.createPopoutTask() {
                  openWindow(value: TaskWindowRoute(taskID: task.id, dataRoot: store.dataRoot))
                }
              }
              Divider()
              Button("分叉到新任务") { store.forkConversation() }.disabled(!store.canForkConversation)
              Button("刷新任务") { Task { await store.reload() } }.disabled(store.project != nil && !store.connected)
              Button("导出报告…") { Task { await store.exportReport() } }.disabled(
                store.selectedRun == nil || store.selectedRun?.isActive == true || (store.selectedRun?.kind != "chat" && !store.connected))
              if let task = store.selectedTask {
                Button("在新窗口中打开") {
                  openWindow(value: TaskWindowRoute(taskID: task.id, dataRoot: store.dataRoot))
                }
                ShareLink(item: store.taskShareText(task)) {
                  Label("共享任务…", systemImage: "square.and.arrow.up")
                }
                Button("重命名任务") { store.beginRenamingTask(task.id) }
                Button("复制任务内容") { store.copyTaskTranscript(task) }
                Button("复制任务链接") { store.copyTaskDeepLink(task) }
                Divider()
                Button(task.pinned ? "取消置顶" : "置顶任务") {
                  store.updateTask(task.id, pin: !task.pinned)
                }
                Button(task.archived ? "恢复任务" : "归档任务") {
                  store.updateTask(task.id, archive: !task.archived)
                }.disabled(store.conversationRuns.contains { $0.isActive })
              }
            } label: {
              Image(systemName: "ellipsis")
            }.help("任务操作")
          }
        }
      }
      .onChange(of: store.selection) { _, _ in
        store.endWorkspaceTabDrag()
        Task { await store.loadDetails() }
      }
      .onChange(of: store.destination) { _, _ in store.endWorkspaceTabDrag() }
      .onChange(of: store.project) { _, _ in store.showingBranchPicker = false }
      .onChange(of: store.logName) { _, _ in Task { await store.loadDetails() } }
      .alert("重命名项目", isPresented: Binding(
        get: { store.renameProjectPath != nil },
        set: { if !$0 { store.renameProjectPath = nil } })
      ) {
        TextField("名称", text: $store.renameDraft)
        Button("取消", role: .cancel) { store.renameProjectPath = nil }
        Button("保存") {
          if let path = store.renameProjectPath { store.renameProject(path, title: store.renameDraft) }
          store.renameProjectPath = nil
        }.disabled(store.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .onReceive(NotificationCenter.default.publisher(for: .toggleShipiOSSidebar)) { _ in
        guard store.destination != .settings else { return }
        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
      }
      .task {
        while !Task.isCancelled {
          await store.runDueAutomations()
          try? await Task.sleep(for: .seconds(30))
        }
      }
    }
    .tabDragLifecycle(session: store.workspaceTabDragSessionID) { store.endWorkspaceTabDrag(session: $0) }
    .disabled(store.renameTaskID != nil)
    .accessibilityHidden(store.renameTaskID != nil)
    .overlay {
      if let id = store.renameTaskID {
        TaskRenameDialog(initialTitle: store.renameDraft,
          save: { try renameHistory.rename(store: store, taskID: id, title: $0) },
          close: { store.renameTaskID = nil; store.focusComposer = UUID() })
          .id(id)
      }
    }
    .focusedSceneValue(\.taskRenameActive, store.renameTaskID != nil)
    .taskRenameUndo(store: store, history: renameHistory,
      blocked: store.renameTaskID != nil || store.presentedOverlay != nil || store.hasSettingsConfirmation
        || store.destination != .workspace || store.showingModelPicker || store.showingBranchPicker, revealInMain: true)
    .overlay(alignment: .top) {
      if store.draggingWorkspaceTabID != nil {
        VStack(spacing: 8) {
          WorkspaceTabNewWindowDropTarget(store: store) { id in
            store.moveWorkspaceTab(id, to: .detached)
            openWindow(value: WorkspaceTabWindowRoute(tabID: id))
          }
          if let cue = store.workspaceTabDropTarget?.cue(side: store.workspaceContentPaneSide), store.workspaceTabDropTarget != .newWindow {
            Label(cue.title, systemImage: cue.icon)
              .appFont(.callout)
              .padding(.horizontal, 14).padding(.vertical, 8)
              .background(.regularMaterial, in: Capsule())
              .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
              .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
              .allowsHitTesting(false)
          }
        }
        .padding(.top, 46)
      }
    }
    .tint(store.appearance.accentHex == nil ? .primary : store.appearance.accentColor)
  }

  @ViewBuilder private var inspectorContent: some View {
    if store.visibleWorkspaceContentTabs(in: .right).isEmpty {
      DeveloperPanel(store: store)
    } else {
      WorkspaceSidePanel(store: store)
    }
  }

  private func mainWorkspaceColumn(
    width: CGFloat, height: CGFloat, terminalHeight: CGFloat
  ) -> some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        if store.showingWorkspaceTabs {
          WorkspaceTabStrip(store: store)
          Divider()
        }
        if let tab = store.activeWorkspaceContentTab {
          WorkspaceTabContentView(store: store, tab: tab)
        } else {
          if let error = store.error {
            HStack(alignment: .top) {
              Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
              Text(error).appFont(.callout).textSelection(.enabled)
              Spacer()
              Button { store.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("关闭提示")
            }.padding(12).background(.orange.opacity(0.08))
          }
          if store.showingFind { ConversationFindBar(store: store) }
          ConversationView(store: store)
            .frame(minHeight: 0, maxHeight: .infinity)
          ComposerView(store: store).padding(.horizontal, 24).padding(.bottom, 12)
        }
      }
      .frame(maxHeight: .infinity)
      .workspaceTabDropDestination(store: store, placement: .left)
      if store.showingTerminal && !store.visibleWorkspaceContentTabs(in: .bottom).isEmpty {
        PanelResizeHandle(
          axis: .horizontal, value: terminalHeight,
          bounds: WorkspacePanelSizes.terminalBounds(available: height),
          label: "调整终端高度", onResize: store.resizeTerminal,
          onEnd: store.saveLibrary, onReset: store.resetTerminalSize
        )
        .frame(height: WorkspacePanelSizes.divider)
        VStack(spacing: 0) {
          WorkspaceTabStrip(store: store, placement: .bottom, includesChat: false)
          Divider()
          TerminalPanel(store: store)
        }
        .frame(height: terminalHeight)
        .workspaceTabDropDestination(store: store, placement: .bottom)
      }
    }
    .frame(width: width, height: height)
    .overlay(alignment: store.workspaceContentPaneSide == .right ? .trailing : .leading) {
      if !store.showingInspector, store.canDropWorkspaceTab(to: .right) {
        hiddenPanelDropTarget(.right,
          title: store.workspaceContentPaneSide == .right ? "移到右侧" : "移到左侧",
          icon: store.workspaceContentPaneSide == .right ? "rectangle.trailinghalf.inset.filled" : "rectangle.leadinghalf.inset.filled")
          .frame(width: min(150, width * 0.22))
          .padding(.vertical, showsHiddenBottomDropTarget ? 90 : 8)
      }
    }
    .overlay(alignment: .bottom) {
      if showsHiddenBottomDropTarget {
        hiddenPanelDropTarget(.bottom, title: "移到底部", icon: "rectangle.bottomhalf.inset.filled")
          .frame(height: 84).padding(8)
      }
    }
  }

  private var showsHiddenBottomDropTarget: Bool {
    (!store.showingTerminal || store.visibleWorkspaceContentTabs(in: .bottom).isEmpty)
      && store.canDropWorkspaceTab(to: .bottom)
  }

  private func hiddenPanelDropTarget(_ placement: WorkspaceTabPlacement, title: String, icon: String) -> some View {
    Label(title, systemImage: icon)
      .appFont(.callout)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
      .workspaceTabDropDestination(store: store, placement: placement)
      .accessibilityLabel(title)
  }

  private func inspectorResizeHandle(availableWidth: CGFloat) -> some View {
    PanelResizeHandle(
      axis: .vertical, growsTowardLeading: store.workspaceContentPaneSide == .right,
      value: store.panelSizes.inspector(available: availableWidth),
      bounds: WorkspacePanelSizes.inspectorBounds(available: availableWidth),
      label: "调整内容面板宽度", onResize: store.resizeInspector,
      onEnd: store.saveLibrary, onReset: store.resetInspectorSize
    )
    .frame(width: WorkspacePanelSizes.divider)
  }

  private func inspectorColumn(width: CGFloat, height: CGFloat) -> some View {
    inspectorContent
      .frame(width: width, height: height)
      .workspaceTabDropDestination(store: store, placement: .right)
  }
}

private extension WorkspaceTabDropTarget {
  func cue(side: WorkspacePaneSide) -> (title: String, icon: String) {
    switch self {
    case .placement(.left): side == .right
      ? ("移到左侧", "rectangle.leadinghalf.inset.filled") : ("移到右侧", "rectangle.trailinghalf.inset.filled")
    case .placement(.right): side == .right
      ? ("移到右侧", "rectangle.trailinghalf.inset.filled") : ("移到左侧", "rectangle.leadinghalf.inset.filled")
    case .placement(.bottom): ("移到底部", "rectangle.bottomhalf.inset.filled")
    case .placement(.detached), .newWindow: ("在新窗口中打开", "macwindow.badge.plus")
    case .pin: ("固定标签页", "pin")
    case .chat: ("移到聊天", "text.bubble")
    case .newChat: ("移到新聊天", "square.and.pencil")
    }
  }
}

private struct WorkspaceTabNewWindowDropTarget: View {
  @Bindable var store: WorkspaceStore
  let detach: (String) -> Void

  var body: some View {
    Label("松开放到新窗口", systemImage: "macwindow.badge.plus")
      .appFont(.callout)
      .padding(.horizontal, 18)
      .padding(.vertical, 11)
      .background(.regularMaterial, in: Capsule())
      .overlay {
        Capsule().stroke(
          store.workspaceTabDropTarget == .newWindow ? Color.accentColor : Color.secondary.opacity(0.35),
          lineWidth: store.workspaceTabDropTarget == .newWindow ? 2 : 1)
      }
      .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
      .dropDestination(for: String.self) { values, _ in
        defer { store.endWorkspaceTabDrag() }
        guard let id = values.compactMap(WorkspaceTabDragToken.decode).first,
          store.canMoveWorkspaceTab(id, to: .detached) else { return false }
        detach(id)
        return true
      } isTargeted: { targeted in
        if targeted {
          store.workspaceTabDropTarget = .newWindow
        } else if store.workspaceTabDropTarget == .newWindow {
          store.workspaceTabDropTarget = nil
        }
      }
      .accessibilityLabel("拖到新窗口")
  }
}

extension Notification.Name {
  static let toggleShipiOSSidebar = Notification.Name("toggleShipiOSSidebar")
}

struct StatusLabel: View {
  let run: AgentRun
  var body: some View { Label(run.statusLabel, systemImage: icon).foregroundStyle(color) }
  var icon: String {
    switch run.status {
    case "succeeded": return "checkmark.circle"
    case "failed": return "exclamationmark.circle"
    case "queued", "running": return "circle.dotted"
    default: return "stop.circle"
    }
  }
  var color: Color {
    switch run.status {
    case "succeeded": return .green
    case "failed": return .orange
    default: return .secondary
    }
  }
}
