import AppKit
import SwiftUI

struct PopoutHomeView: View {
  @Bindable var store: WorkspaceStore
  let onSubmit: (String, String?, NewTaskExecution) async -> Bool
  let onOpenThread: (String) -> Void
  let onHide: () -> Void
  @State private var selectedProject: String?
  @State private var choseProject = false
  @State private var execution = NewTaskExecution.local
  @State private var worktreeEligible = false
  @State private var submitting = false
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var previewFile: FileAttachment?
  @State private var previewImage: ImagePreviewItem?
  @State private var previewImages: [ImagePreviewItem] = []
  @State private var imagePreviewReturnFocus: (() -> Void)?
  @State private var slashSelection = PopoutSlashSelection()
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue
  private var draft: Binding<String> {
    Binding(get: { store.popoutHomeDraft }, set: { store.popoutHomeDraft = $0 })
  }
  private var hasContent: Bool {
    !store.popoutHomeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !store.popoutHomeImages.isEmpty || !store.popoutHomeFiles.isEmpty
  }
  private var currentProjectChoice: String? {
    let current = store.library.projectOwner(for: store.currentProjectKey)
    return current.isEmpty ? nil : current
  }
  private var defaultProject: String? {
    store.popoutWindowProjectlessDefault ? nil : currentProjectChoice
  }
  private var projectChoices: [String] {
    Array(Set(store.library.projects + (currentProjectChoice.map { [$0] } ?? []))).sorted {
      store.library.projectTitle($0).localizedStandardCompare(
        store.library.projectTitle($1)) == .orderedAscending
    }
  }
  private var composerPlaceholder: String {
    guard let selectedProject else { return "在任何项目外提问，或输入 / 选择操作…" }
    let title = store.library.projectTitle(selectedProject)
    return execution == .worktree
      ? "在 \(title) 的工作树中提问…"
      : "在 \(title) 中提问，或输入 / 选择操作…"
  }

  init(store: WorkspaceStore,
    onSubmit: @escaping (String, String?, NewTaskExecution) async -> Bool,
    onOpenThread: @escaping (String) -> Void, onHide: @escaping () -> Void) {
    self.store = store
    self.onSubmit = onSubmit
    self.onOpenThread = onOpenThread
    self.onHide = onHide
    let current = store.library.projectOwner(for: store.currentProjectKey)
    _selectedProject = State(initialValue: store.popoutWindowProjectlessDefault
      || current.isEmpty ? nil : current)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text("新任务").appFont(size: 16, weight: .semibold)
        Spacer()
        Button { onHide() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("隐藏弹出窗口")
      }
      if !store.popoutHomeImages.isEmpty || !store.popoutHomeFiles.isEmpty {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 6) {
            ImageAttachmentsView(store: store, images: store.popoutHomeImages, removable: true,
              onRemove: { store.removeDraftImage($0, draft: WorkspaceStore.popoutHomeDraftKey) })
            FileAttachmentsView(store: store, files: store.popoutHomeFiles, removable: true,
              onPreview: { previewFile = $0 },
              onRemove: { store.removeDraftFile($0, draft: WorkspaceStore.popoutHomeDraftKey) })
          }
        }.frame(maxHeight: 100)
      }
      ComposerTextEditor(text: draft,
        focused: $focused, plainTextMode: store.composerPlainTextMode,
        placeholder: composerPlaceholder,
        accessibilityLabel: "弹出窗口消息", focusRequest: focusRequest,
        onKey: { key, modifiers, composing in
          if handleSlashKey(key, modifiers: modifiers, composing: composing) { return true }
          guard shouldSubmit(key, modifiers: modifiers, composing: composing,
            text: draft.wrappedValue, shortcut: sendShortcut, store: store) else { return false }
          submit()
          return true
        }, onPasteAttachments: { store.pasteAttachments($0, draft: WorkspaceStore.popoutHomeDraftKey) })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(submitting)
      if let error = store.generalSettingsError {
        Text(error).appFont(.caption).foregroundStyle(.red)
      }
      if let error = store.error {
        Text(error).appFont(.caption).foregroundStyle(.red)
      }
      controls
    }
    .padding(20)
    .frame(minWidth: 400, minHeight: 250)
    .overlay(alignment: .bottomLeading) {
      if slashSelection.isVisible {
        PopoutSlashMenuView(store: store, selection: $slashSelection, maximumHeight: 172,
          accept: selectSlashItem)
          .padding(.horizontal, 20).padding(.bottom, 61)
      }
    }
    .background(store.appearance.backgroundColor)
    .foregroundStyle(store.appearance.foregroundColor)
    .tint(store.appearance.accentColor)
    .preferredColorScheme(store.appearance.colorScheme)
    .onAppear { focused = true; focusRequest = UUID(); updateSlashSelection() }
    .onChange(of: store.popoutHomeDraft) { _, _ in updateSlashSelection() }
    .onChange(of: store.library.tasks) { _, _ in updateSlashSelection() }
    .onChange(of: store.popoutHomeImages.count + store.popoutHomeFiles.count) { _, _ in
      updateSlashSelection()
    }
    .onChange(of: store.popoutWindowProjectlessDefault) { _, _ in
      if !choseProject && store.popoutHomeDraft.isEmpty { selectedProject = defaultProject }
    }
    .onChange(of: store.currentProjectKey) { _, _ in
      if let selectedProject, !projectChoices.contains(selectedProject) {
        choseProject = false
        self.selectedProject = defaultProject
      } else if !choseProject && store.popoutHomeDraft.isEmpty {
        selectedProject = defaultProject
      }
    }
    .onChange(of: store.library.projects) { _, _ in
      if let selectedProject, !projectChoices.contains(selectedProject) {
        choseProject = false
        self.selectedProject = defaultProject
      }
    }
    .onChange(of: selectedProject) { _, project in
      worktreeEligible = false
      if project == nil { execution = .local }
    }
    .task(id: selectedProject) {
      guard let selectedProject else { worktreeEligible = false; return }
      let source = store.library.primaryFolder(for: selectedProject)
      let eligible = (try? await GitBranchService.snapshot(
        at: URL(fileURLWithPath: source)))?.canChange == true
      guard self.selectedProject == selectedProject else { return }
      worktreeEligible = eligible
      if !eligible { execution = .local }
    }
    .task(id: "\(selectedProject ?? "")|\(execution.rawValue)") {
      if selectedProject != nil, execution == .worktree {
        await store.refreshEnvironmentCatalog()
      }
    }
    .environment(\.presentImageGallery) { image, images, returnFocus in
      guard previewFile == nil, previewImage == nil else { return }
      previewImage = image
      previewImages = images
      imagePreviewReturnFocus = returnFocus
    }
    .sheet(item: $previewFile, onDismiss: restoreComposerFocus) {
      FileAttachmentPreview(file: $0, root: store.dataRoot)
    }
    .sheet(item: $previewImage, onDismiss: restoreImagePreviewFocus) { image in
      ImageGalleryPreview(image: image, images: previewImages, root: store.dataRoot) {
        previewImage = nil
      }.frame(width: 720, height: 520)
    }
    .onExitCommand {
      if previewImage != nil { previewImage = nil }
      else if previewFile != nil { previewFile = nil }
      else if slashSelection.isVisible { _ = slashSelection.handle(.dismiss) }
      else { onHide() }
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Menu {
        Button("添加图片…") { store.chooseImages(draft: WorkspaceStore.popoutHomeDraftKey) }
        Button("添加文件…") { store.chooseFiles(draft: WorkspaceStore.popoutHomeDraftKey) }
      } label: { Image(systemName: "plus") }
        .menuStyle(.borderlessButton).accessibilityLabel("添加弹出窗口附件")
        .disabled(submitting)
      chatSettingsMenu
      Spacer()
      if submitting { ProgressView().controlSize(.small) }
      Button("发送", action: submit)
        .buttonStyle(.borderedProminent)
        .disabled(submitting || !hasContent || !store.libraryLoaded
          || store.importingImages || store.importingFiles
          || (execution == .worktree && !worktreeEligible))
    }
  }

  private var chatSettingsMenu: some View {
    Menu {
      projectMenu
      executionMenu
      environmentMenu
      permissionsMenu
    } label: {
      Label((selectedProject.map { store.library.projectTitle($0) } ?? "独立聊天")
        + (execution == .worktree ? " · 工作树" : ""),
        systemImage: execution == .worktree ? "arrow.triangle.branch" : "folder")
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton).accessibilityLabel("聊天设置")
      .help("项目：" + (selectedProject.map { store.library.projectTitle($0) } ?? "独立聊天"))
      .disabled(submitting)
  }

  private var projectMenu: some View {
    Menu("项目") {
      Button {
        selectedProject = nil
        choseProject = true
      } label: {
        if selectedProject == nil { Label("独立聊天", systemImage: "checkmark") }
        else { Text("独立聊天") }
      }
      Divider()
      ForEach(projectChoices, id: \.self) { project in
        Button {
          selectedProject = project
          choseProject = true
        } label: {
          if selectedProject == project {
            Label(store.library.projectTitle(project), systemImage: "checkmark")
          } else {
            Text(store.library.projectTitle(project))
          }
        }
      }
    }
  }

  private var executionMenu: some View {
    Menu("启动模式") {
      ForEach(NewTaskExecution.allCases) { choice in
        Button {
          execution = choice
        } label: {
          if execution == choice { Label(choice.title, systemImage: "checkmark") }
          else { Text(choice.title) }
        }
        .disabled(choice == .worktree && !worktreeEligible)
        .help(choice == .worktree && !worktreeEligible
          ? "初始化 Git 代码仓库以在工作树中运行任务" : "")
      }
    }
  }

  private var environmentMenu: some View {
    Menu("环境") {
      if let selectedProject {
        let selection = store.popoutEnvironmentSelection(project: selectedProject)
        environmentOption("项目默认", id: AutomationEnvironmentChoice.projectDefault,
          selected: selection, project: selectedProject)
        environmentOption("无环境", id: WorktreeEnvironmentChoice.none,
          selected: selection, project: selectedProject)
        environmentOption("ShipiOS 本地配置", id: WorktreeEnvironmentChoice.legacy,
          selected: selection, project: selectedProject)
        Divider()
        ForEach(store.environmentCatalog[selectedProject]?.filter { $0.error == nil } ?? []) { entry in
          environmentOption(entry.title, id: entry.id, selected: selection,
            project: selectedProject)
        }
        if store.environmentCatalogLoading {
          Text("正在读取项目环境…")
        } else if let error = store.environmentCatalogErrors[selectedProject] {
          Text("环境列表读取失败：\(error)")
        } else if store.environmentCatalog[selectedProject]?.isEmpty == true {
          Text("没有环境文件")
        }
        Divider()
        Button("刷新环境列表") { Task { await store.refreshEnvironmentCatalog() } }
          .disabled(store.environmentCatalogLoading)
      }
    }
    .disabled(selectedProject == nil || execution != .worktree || submitting
      || selectedProject.map {
        store.library.pendingPopoutWorktreeTaskIDs[store.library.primaryFolder(for: $0)] != nil
      } == true)
    .help(execution == .worktree ? "选择此工作树任务的环境" : "选择工作树模式后设置环境")
  }

  private func environmentOption(_ title: String, id: String, selected: String,
    project: String) -> some View {
    Button {
      _ = store.setPopoutEnvironmentSelection(id, project: project)
    } label: {
      if selected == id { Label(title, systemImage: "checkmark") }
      else { Text(title) }
    }
  }

  private var permissionsMenu: some View {
    Menu("权限") {
      let effective = store.library.popoutHomeRuntimePreferences
        ?? store.library.agentRuntimePreferences
      Button {
        _ = store.savePopoutHomeRuntimePreferences(nil)
      } label: {
        if store.library.popoutHomeRuntimePreferences == nil {
          Label("沿用全局设置", systemImage: "checkmark")
        } else { Text("沿用全局设置") }
      }
      Divider()
      Menu("审批策略") {
        ForEach(AgentApprovalPolicy.allCases, id: \.self) { policy in
          Button {
            var choice = effective
            choice.approvalPolicy = policy
            _ = store.savePopoutHomeRuntimePreferences(choice)
          } label: {
            if effective.approvalPolicy == policy {
              Label(policy.title, systemImage: "checkmark")
            } else { Text(policy.title) }
          }
        }
      }
      Menu("文件访问") {
        ForEach(AgentSandboxMode.allCases, id: \.self) { mode in
          Button {
            var choice = effective
            choice.sandboxMode = mode
            if mode != .workspaceWrite { choice.networkAccess = false }
            _ = store.savePopoutHomeRuntimePreferences(choice)
          } label: {
            if effective.sandboxMode == mode {
              Label(mode.title, systemImage: "checkmark")
            } else { Text(mode.title) }
          }
        }
      }
      if effective.sandboxMode == .workspaceWrite {
        Button {
          var choice = effective
          choice.networkAccess.toggle()
          _ = store.savePopoutHomeRuntimePreferences(choice)
        } label: {
          if effective.networkAccess {
            Label("允许网络访问", systemImage: "checkmark")
          } else { Text("允许网络访问") }
        }
      }
    }
    .disabled(submitting)
    .help("为弹出窗口创建的新任务选择 Codex Core 权限")
  }

  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func submit() {
    guard !submitting, store.libraryLoaded, !store.importingImages,
      !store.importingFiles, hasContent,
      execution != .worktree || worktreeEligible else { return }
    let prompt = draft.wrappedValue
    let project = selectedProject
    let mode = execution
    submitting = true
    Task {
      _ = await onSubmit(prompt, project, mode)
      submitting = false
    }
  }

  private func restoreComposerFocus() {
    focused = true
    focusRequest = UUID()
  }

  private func restoreImagePreviewFocus() {
    let returnFocus = imagePreviewReturnFocus
    imagePreviewReturnFocus = nil
    if let returnFocus { returnFocus() }
    else { restoreComposerFocus() }
  }

  private func updateSlashSelection() {
    slashSelection.update(draft: store.popoutHomeDraft, canNew: false,
      tasks: store.library.tasks, currentTaskID: nil,
      hasAttachments: !store.popoutHomeImages.isEmpty || !store.popoutHomeFiles.isEmpty)
  }

  private func handleSlashKey(_ key: ComposerEditorKey,
    modifiers: NSEvent.ModifierFlags, composing: Bool) -> Bool {
    guard modifiers.isEmpty else { return false }
    updateSlashSelection()
    switch slashSelection.handle(popoutSlashKey(key), isComposing: composing) {
    case .ignored: return false
    case .handled: return true
    case .accept(let item): selectSlashItem(item); return true
    }
  }

  private func selectSlashItem(_ item: PopoutSlashItem) {
    if case .task(let id) = item {
      store.popoutHomeDraft = ""
      onOpenThread(id)
    }
  }
}

struct PopoutThreadView: View {
  @Bindable var store: WorkspaceStore
  let taskID: String
  let onHome: () -> Void
  let onOpenThread: (String) -> Void
  let onOpenInMain: (String) -> Void
  let onHide: () -> Void
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var slashSelection = PopoutSlashSelection()
  @State private var previewFile: FileAttachment?
  @State private var previewImage: ImagePreviewItem?
  @State private var previewImages: [ImagePreviewItem] = []
  @State private var imagePreviewReturnFocus: (() -> Void)?
  @State private var inspectedRun: AgentRun?
  @State private var inspectorTab = "overview"
  @State private var scrolling = ConversationScrollState()
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue
  private var runs: [AgentRun] { store.taskWindowRuns(taskID) }
  private struct RunRevision: Equatable {
    let id: String
    let updatedAt: Double
    let status: String
  }
  private var runRevisions: [RunRevision] {
    runs.map { RunRevision(id: $0.id, updatedAt: $0.updatedAt, status: $0.status) }
  }
  private var task: WorkspaceTask? { store.library.tasks.first { $0.id == taskID } }
  private var queuedCount: Int {
    store.library.queuedMessages.filter { $0.taskID == taskID }.count
  }
  private var attachmentHeight: CGFloat {
    let hasImages = !store.taskWindowImages(taskID).isEmpty
    let hasFiles = !store.taskWindowFiles(taskID).isEmpty
    return (hasImages ? 110 : 0) + (hasFiles ? 54 : 0) + (hasImages && hasFiles ? 6 : 0)
  }
  private var canSend: Bool {
    (store.canStartChat(taskID: taskID) || store.activeChatRun(taskID: taskID) != nil)
      && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !store.taskWindowImages(taskID).isEmpty || !store.taskWindowFiles(taskID).isEmpty)
      && !store.importingImages && !store.importingFiles
  }
  private var draft: Binding<String> {
    Binding(get: { store.taskWindowDraft(taskID) },
      set: { store.setTaskWindowDraft($0, taskID: taskID) })
  }
  private var messageActions: ExecutionMessageActions {
    ExecutionMessageActions(
      previewFile: { previewFile = $0 },
      inspect: { run, tab in inspectedRun = run; inspectorTab = tab },
      canRerun: { store.canRerunTaskWindowChat($0, taskID: taskID) },
      rerun: { run in Task { await store.rerunTaskWindowChat(run, taskID: taskID) } },
      canFork: { store.canForkTaskWindow(taskID, through: $0.id) },
      fork: { run in forkConversation(through: run.id) },
      canContinuePlan: { _ in store.canStartChat(taskID: taskID) },
      continuePlan: { run in
        store.continueFromPlan(run, taskID: taskID)
        focused = true
        focusRequest = UUID()
      })
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button { onHome() } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).accessibilityLabel("返回")
        Text(task?.title ?? "会话").lineLimit(1).appFont(size: 14, weight: .semibold)
        Spacer()
        Button { onHome() } label: { Image(systemName: "square.and.pencil") }
          .buttonStyle(.plain).help("开始新对话").accessibilityLabel("开始新对话")
        Button { onOpenInMain(taskID) } label: { Image(systemName: "arrow.up.right.square") }
          .buttonStyle(.plain).help("在主窗口中打开")
          .accessibilityLabel("在主窗口中打开")
          .disabled(task?.isTransient != false)
        Button { onHide() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("隐藏弹出窗口")
      }.padding(.horizontal, 18).padding(.vertical, 14)
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 25) {
            ForEach(runs) { run in
              ExecutionMessageView(store: store, run: run, actions: messageActions).id(run.id)
            }
            Color.clear.frame(height: 1).id("end")
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background {
              ConversationScrollObserver { event in
                switch event {
                case .geometry(let metrics):
                  if scrolling.observe(metrics) { reader.scrollTo("end", anchor: .bottom) }
                case .began: scrolling.beginUserScroll()
                case .ended(let metrics): scrolling.endUserScroll(metrics)
                }
              }
            }
        }
        .defaultScrollAnchor(.top)
        .overlay(alignment: .bottom) {
          if !scrolling.isAtBottom {
            Button {
              scrolling.requestLatest()
              reader.scrollTo("end", anchor: .bottom)
            } label: {
              Image(systemName: "arrow.down").appFont(size: 13, weight: .semibold)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.12)))
                .overlay(alignment: .topTrailing) {
                  if scrolling.hasNewContent {
                    Circle().fill(.tint).frame(width: 7, height: 7)
                  }
                }
            }.buttonStyle(.plain).padding(.bottom, 12)
              .help(scrolling.hasNewContent ? "有新内容，返回底部" : "返回底部")
              .accessibilityLabel(scrolling.hasNewContent ? "有新内容，返回底部" : "返回底部")
          }
        }
        .onChange(of: runRevisions) { _, _ in
          if scrolling.contentChanged() { reader.scrollTo("end", anchor: .bottom) }
        }
      }
      Divider()
      if queuedCount > 0 {
        ScrollView {
          ComposerQueueView(store: store, taskID: taskID)
        }
        .frame(height: min(CGFloat(queuedCount) * 48, 112))
        .padding(.horizontal, 14).padding(.top, 10)
      }
      if let active = store.activeRun(taskID: taskID) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(active.title).appFont(.caption).foregroundStyle(.secondary)
          Spacer()
        }.padding(.horizontal, 16).padding(.top, 8)
      }
      if !store.taskWindowImages(taskID).isEmpty || !store.taskWindowFiles(taskID).isEmpty {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 6) {
            ImageAttachmentsView(store: store, images: store.taskWindowImages(taskID),
              removable: true, onRemove: { store.removeDraftImage($0, draft: taskID) })
            FileAttachmentsView(store: store, files: store.taskWindowFiles(taskID),
              removable: true, onPreview: { previewFile = $0 },
              onRemove: { store.removeDraftFile($0, draft: taskID) })
          }
        }.frame(height: attachmentHeight).padding(.horizontal, 14).padding(.top, 10)
      }
      if let error = store.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button {
            store.error = nil
          } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).help("关闭提示")
        }
        .appFont(.caption).padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
      }
      HStack(alignment: .bottom, spacing: 8) {
        Menu {
          Button("添加图片…") { store.chooseImages(draft: taskID) }
          Button("添加文件…") { store.chooseFiles(draft: taskID) }
        } label: { Image(systemName: "plus") }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("添加弹出会话附件")
          .disabled(store.importingImages || store.importingFiles)
        ComposerTextEditor(text: draft,
          focused: $focused, plainTextMode: store.composerPlainTextMode,
          placeholder: "继续这个任务…", accessibilityLabel: "弹出会话消息",
          focusRequest: focusRequest,
          onKey: { key, modifiers, composing in
            if handleSlashKey(key, modifiers: modifiers, composing: composing) { return true }
            guard shouldSubmit(key, modifiers: modifiers, composing: composing,
              text: draft.wrappedValue, shortcut: sendShortcut, store: store) else { return false }
            submit()
            return true
          }, onPasteAttachments: { store.pasteAttachments($0, draft: taskID) })
          .frame(minHeight: 48, maxHeight: 90)
        if store.taskWindowOwnsActiveRun(taskID) {
          Button {
            Task { await store.cancel(taskID: taskID) }
          } label: {
            Image(systemName: "stop.fill").frame(width: 28, height: 28)
          }
          .buttonStyle(.bordered).clipShape(Circle())
          .help("停止任务").accessibilityLabel("停止弹出会话任务")
        }
        Button {
          submit()
        } label: { Image(systemName: "arrow.up") }
          .buttonStyle(.borderedProminent)
          .disabled(!canSend)
          .help(store.activeChatRun(taskID: taskID) == nil
            ? "发送消息" : store.followUpBehavior.composerLabel)
          .accessibilityLabel("发送弹出会话消息")
      }.padding(14)
    }
    .frame(minWidth: 400, minHeight: 400)
    .overlay(alignment: .bottomLeading) {
      if slashSelection.isVisible {
        PopoutSlashMenuView(store: store, selection: $slashSelection, maximumHeight: 264,
          accept: selectSlashItem)
          .padding(.horizontal, 14).padding(.bottom, 84)
      }
    }
    .background(store.appearance.backgroundColor)
    .foregroundStyle(store.appearance.foregroundColor)
    .tint(store.appearance.accentColor)
    .preferredColorScheme(store.appearance.colorScheme)
    .onAppear { focused = true; focusRequest = UUID(); updateSlashSelection() }
    .onChange(of: draft.wrappedValue) { _, _ in updateSlashSelection() }
    .onChange(of: store.library.tasks) { _, _ in updateSlashSelection() }
    .onChange(of: store.taskWindowImages(taskID).count + store.taskWindowFiles(taskID).count) {
      _, _ in updateSlashSelection()
    }
    .environment(\.presentImageGallery) { image, images, returnFocus in
      guard previewFile == nil, previewImage == nil else { return }
      previewImage = image
      previewImages = images
      imagePreviewReturnFocus = returnFocus
    }
    .sheet(item: $previewFile, onDismiss: restoreComposerFocus) {
      FileAttachmentPreview(file: $0, root: store.dataRoot)
    }
    .sheet(item: $previewImage, onDismiss: restoreImagePreviewFocus) { image in
      ImageGalleryPreview(image: image, images: previewImages, root: store.dataRoot) {
        previewImage = nil
      }.frame(width: 720, height: 520)
    }
    .sheet(item: $inspectedRun) { selected in
      Group {
        if selected.kind == "chat" {
          ChatRunInspectorView(store: store,
            run: runs.first(where: { $0.id == selected.id }) ?? selected,
            tab: $inspectorTab, close: { inspectedRun = nil })
        } else {
          PopoutLocalRunDetailsView(run: selected, tab: $inspectorTab,
            close: { inspectedRun = nil })
        }
      }.frame(width: 600, height: 540)
    }
    .onExitCommand {
      if inspectedRun != nil { inspectedRun = nil }
      else if previewImage != nil { previewImage = nil }
      else if previewFile != nil { previewFile = nil }
      else if slashSelection.isVisible { _ = slashSelection.handle(.dismiss) }
      else { onHide() }
    }
  }

  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func submit() {
    guard canSend else { return }
    Task { await store.sendTaskWindowDraft(taskID, mode: .standard) }
  }

  private func restoreComposerFocus() {
    focused = true
    focusRequest = UUID()
  }

  private func restoreImagePreviewFocus() {
    let returnFocus = imagePreviewReturnFocus
    imagePreviewReturnFocus = nil
    if let returnFocus { returnFocus() }
    else { restoreComposerFocus() }
  }

  private func forkConversation(through runID: String) {
    do {
      let fork = try store.forkTaskWindowConversation(taskID, through: runID)
      onOpenThread(fork.id)
    } catch { store.error = error.localizedDescription }
  }

  private func updateSlashSelection() {
    slashSelection.update(draft: draft.wrappedValue, canNew: true,
      tasks: store.library.tasks, currentTaskID: taskID,
      hasAttachments: !store.taskWindowImages(taskID).isEmpty
        || !store.taskWindowFiles(taskID).isEmpty)
  }

  private func handleSlashKey(_ key: ComposerEditorKey,
    modifiers: NSEvent.ModifierFlags, composing: Bool) -> Bool {
    guard modifiers.isEmpty else { return false }
    updateSlashSelection()
    switch slashSelection.handle(popoutSlashKey(key), isComposing: composing) {
    case .ignored: return false
    case .handled: return true
    case .accept(let item): selectSlashItem(item); return true
    }
  }

  private func selectSlashItem(_ item: PopoutSlashItem) {
    switch item {
    case .new:
      store.setTaskWindowDraft("", taskID: taskID)
      store.discardPopoutTaskIfEmpty(taskID)
      onHome()
    case .task(let id):
      store.setTaskWindowDraft("", taskID: taskID)
      store.discardPopoutTaskIfEmpty(taskID)
      onOpenThread(id)
    case .resume, .empty: break
    }
  }
}

private struct PopoutLocalRunDetailsView: View {
  let run: AgentRun
  @Binding var tab: String
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("执行详情").appFont(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("关闭执行详情")
      }.padding(16)
      Picker("详情", selection: $tab) {
        Text("诊断").tag("diagnostics")
        Text("日志").tag("logs")
        Text("产物").tag("artifacts")
      }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 14)
      Divider()
      HStack {
        StatusLabel(run: run)
        Spacer()
        Text(run.date, style: .time).foregroundStyle(.secondary)
      }.appFont(.caption).padding(14)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          switch tab {
          case "logs":
            Text(run.result?["command"]["stdout"].text ?? "标准输出为空。")
              .appFont(size: 11, design: .monospaced).textSelection(.enabled)
            if let stderr = run.result?["command"]["stderr"].text, !stderr.isEmpty {
              Divider()
              Text(stderr).appFont(size: 11, design: .monospaced).textSelection(.enabled)
            }
          case "artifacts":
            LabeledContent("类型", value: run.kind == "doctor" ? "环境诊断" : "构建")
            if let directory = run.result?["artifactDirectory"].text {
              LabeledContent("产物目录", value: directory)
            }
            if let code = run.result?["command"]["exitCode"].int {
              LabeledContent("退出码", value: String(code))
            }
          default:
            let diagnostics = run.result?["command"]["diagnostics"].items ?? []
            if diagnostics.isEmpty { Text("没有编译器诊断").foregroundStyle(.secondary) }
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, item in
              VStack(alignment: .leading, spacing: 5) {
                Text(item["message"].text ?? "").textSelection(.enabled)
                if let file = item["file"].text {
                  Text(file + (item["line"].int.map { ":\($0)" } ?? ""))
                    .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
              }
              Divider()
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
      }
    }
  }
}

private func popoutSlashKey(_ key: ComposerEditorKey) -> PopoutSlashSelection.Key {
  switch key {
  case .up: .previous
  case .down: .next
  case .escape: .dismiss
  case .enter, .tab: .accept
  }
}

@MainActor private func shouldSubmit(_ key: ComposerEditorKey, modifiers: NSEvent.ModifierFlags,
  composing: Bool, text: String, shortcut: ComposerSendShortcut,
  store: WorkspaceStore) -> Bool {
  guard !composing, key == .enter else { return false }
  if modifiers.isEmpty { return shortcut.sendsOnPlainReturn(text) }
  return modifiers == .command && store.shortcuts.matches("send", ShortcutBinding("⌘↵"))
}
