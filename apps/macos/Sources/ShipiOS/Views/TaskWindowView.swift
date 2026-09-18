import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskWindowView: View {
  @Bindable var store: WorkspaceStore
  let taskID: String
  let renameHistory: TaskRenameHistory
  let onNavigate: (String) -> Void
  let canGoBack: Bool
  let canGoForward: Bool
  let onMove: (Bool) -> Void
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @State private var forkError: String?
  @State private var mode = ChatMode.standard
  @State private var commandSelection = ComposerCommandSelection()
  @State private var pluginSelection = PluginMentionSelection()
  @State private var skillSelection = SkillMentionSelection()
  @State private var previewFile: FileAttachment?
  @State private var previewImage: ImagePreviewItem?
  @State private var imagePreviewReturnFocus: (() -> Void)?
  @State private var previewImages: [ImagePreviewItem] = []
  @State private var showingGoalEditor = false
  @State private var showingTaskModelPicker = false
  @State private var renameTitle: String?
  @State private var dropTargeted = false
  @State private var showingFind = false
  @State private var findText = ""
  @State private var findMatches: [ConversationMatch] = []
  @State private var findIndex = 0
  @State private var findRequest = UUID()
  @State private var findFocusRequest = UUID()
  @State private var finding = false
  @State private var mountedTexts: Set<ConversationTextID> = []
  @State private var mountedOccurrences: Set<ConversationMatch.ID> = []
  @State private var pendingText: ConversationTextID?
  @State private var pendingMatch: ConversationMatch.ID?
  @State private var showingFiles = false
  @State private var showingFileSearch = false
  @State private var fileFocusAfterSearch: String?
  @State private var showingReview = false
  @State private var showingTerminal = false
  @State private var taskWorkspace = DeveloperWorkspace()
  @State private var terminalSession: TerminalSession?
  @State private var taskComposerFocusRequest = UUID()
  @State private var composerFocused = false
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue

  private struct RunRevision: Equatable {
    let id: String
    let updatedAt: Double
    let status: String
  }
  private struct FindRevision: Equatable {
    let query: String
    let runs: [RunRevision]
  }

  private var task: WorkspaceTask? { store.library.tasks.first { $0.id == taskID } }
  private var taskRuns: [AgentRun] { store.taskWindowRuns(taskID) }
  private var draft: Binding<String> {
    Binding(
      get: { store.taskWindowDraft(taskID) },
      set: { store.setTaskWindowDraft($0, taskID: taskID) })
  }
  private var canSend: Bool {
    guard task != nil else { return false }
    if store.taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.files.token {
      return task?.project.isEmpty == false
    }
    if store.taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.fork.token {
      return store.canForkTaskWindow(taskID)
    }
    return store.canStartChat(taskID: taskID)
      && (!store.taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !store.taskWindowImages(taskID).isEmpty || !store.taskWindowFiles(taskID).isEmpty)
  }
  private var activeFindMatch: ConversationMatch? {
    guard showingFind, findMatches.indices.contains(findIndex) else { return nil }
    return findMatches[findIndex]
  }
  private var findRevision: FindRevision {
    FindRevision(
      query: showingFind ? findText : "",
      runs: taskRuns.map { RunRevision(id: $0.id, updatedAt: $0.updatedAt, status: $0.status) })
  }

  var body: some View {
    Group {
      if let task {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              if showingFind {
                TaskWindowFindBar(
                  text: $findText, count: findMatches.count, index: findIndex, finding: finding,
                  focusRequest: findFocusRequest, shortcuts: store.shortcuts,
                  previous: { moveFindMatch(-1) }, next: { moveFindMatch(1) },
                  close: { closeFind() })
                Divider()
              }
              if let forkError {
                HStack {
                  Text(forkError).foregroundStyle(.red).textSelection(.enabled)
                  Spacer()
                  Button { self.forkError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭分叉错误")
                }.padding(12)
              }
              taskTimeline
              Divider()
              taskComposer(task)
              if showingTerminal, let session = terminalSession {
                Divider()
                TaskWindowTerminalPanel(
                  session: session, task: task,
                  hide: { showingTerminal = false }, restart: { restartTerminal(task) })
                .frame(height: min(300, max(180, geometry.size.height * 0.34)))
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showingFiles {
              Divider()
              TaskWindowFilesPanel(
                store: store, workspace: taskWorkspace, close: { showingFiles = false })
              .frame(width: min(380, max(300, geometry.size.width * 0.38)))
            } else if showingReview {
              Divider()
              TaskWindowReviewPanel(
                store: store, workspace: taskWorkspace, taskID: taskID,
                close: { showingReview = false }, focusComposer: { composerFocused = true })
              .frame(width: min(430, max(330, geometry.size.width * 0.43)))
            }
          }
        }
        .task(id: task.project) {
          configureTaskWorkspace()
          await taskWorkspace.refreshFiles()
        }
        .navigationTitle(task.title)
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            Button {
              showingFind = true
              findFocusRequest = UUID()
            } label: {
              Image(systemName: "text.magnifyingglass")
            }
            .help("在当前任务中查找 " + store.shortcuts.label("find"))

            if !task.project.isEmpty {
              Button { openTaskFileSearch() } label: { Image(systemName: "doc.text.magnifyingglass") }
                .help("搜索任务文件 " + store.shortcuts.label("files")).accessibilityLabel("搜索任务文件")
              Button {
                showingReview = false
                showingFiles.toggle()
              } label: {
                Image(systemName: "doc")
              }
              .help("显示或隐藏任务文件")
              .accessibilityLabel("任务文件")
              Button {
                showingFiles = false
                showingReview.toggle()
              } label: {
                Image(systemName: "square.stack.3d.up")
              }
              .help("显示或隐藏任务审查")
              .accessibilityLabel("任务审查")
              Button {
                toggleTerminal(task)
              } label: {
                Image(systemName: "terminal")
              }
              .help("显示或隐藏任务终端")
              .accessibilityLabel("任务终端")
            }
            if !task.isPopoutDraft {
              Menu {
                Button("分叉到新任务") { forkTask() }
                  .disabled(!store.canForkTaskWindow(taskID) || windowCommandsBlocked)
                Button("重命名任务") { performWindowCommand("rename") }
                Button(task.pinned ? "取消置顶" : "置顶任务") { performWindowCommand("pin") }
                Button("标为未读") { performWindowCommand("unread") }
                Button("复制任务内容") { store.copyTaskTranscript(task) }
              } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("任务操作").help("任务操作")
              ShareLink(item: store.taskShareText(task)) {
                Image(systemName: "square.and.arrow.up")
              }.help("共享任务")
            }
            Button {
              store.openSettings()
              openWindow(id: "main")
            } label: {
              Image(systemName: "gearshape")
            }
            .help("在主窗口中打开设置 ⌘,")
            .keyboardShortcut(",", modifiers: .command)
            if !task.isPopoutDraft {
              Button {
                store.selectTask(task)
                openWindow(id: "main")
              } label: {
                Image(systemName: "rectangle.on.rectangle")
              }.help("在主窗口中显示")
            }
          }
        }
      } else {
        ContentUnavailableView(
          "任务不可用", systemImage: "bubble.left.and.exclamationmark.bubble.right",
          description: Text("任务可能已经被永久删除。"))
      }
    }
    .disabled(renameTitle != nil)
    .accessibilityHidden(renameTitle != nil)
    .overlay {
      if let renameTitle {
        TaskRenameDialog(initialTitle: renameTitle,
          save: { try renameHistory.rename(store: store, taskID: taskID, title: $0) },
          close: { self.renameTitle = nil; composerFocused = true; taskComposerFocusRequest = UUID() })
      }
    }
    .focusedSceneValue(\.taskRenameActive, renameTitle != nil)
    .taskRenameUndo(store: store, history: renameHistory, blocked: windowCommandsBlocked, onReveal: onNavigate)
    .frame(minWidth: 620, minHeight: 520)
    .focusedSceneValue(\.taskWindowCommands, windowCommandContext)
    .background(TaskWindowCommandKeyboardBridge(commands: windowCommandContext,
      shortcuts: store.shortcuts, blocked: windowCommandsBlocked).frame(width: 0, height: 0))
    .environment(\.mcpApprovalSurfaceVisible,
      !showingFind && !showingGoalEditor && !showingTaskModelPicker && !showingFileSearch && renameTitle == nil && previewFile == nil && previewImage == nil)
    .background(MCPApprovalKeyboardBridge(store: store, taskID: taskID,
      visible: !showingFind && !showingGoalEditor && !showingTaskModelPicker && !showingFileSearch && renameTitle == nil && previewFile == nil && previewImage == nil)
      .frame(width: 0, height: 0))
    .focusedSceneValue(\.mcpApprovalCommands, store.mcpApprovalCommands(taskID: taskID,
      visible: !showingFind && !showingGoalEditor && !showingTaskModelPicker && !showingFileSearch && renameTitle == nil && previewFile == nil && previewImage == nil))
    .environment(\.presentImageGallery) { image, images, returnFocus in
      guard previewImage == nil, previewFile == nil, !showingGoalEditor, !showingTaskModelPicker, !showingFileSearch, renameTitle == nil else { return }
      imagePreviewReturnFocus = returnFocus
      previewImage = image
      previewImages = images
    }
    .appSurface()
    .disabled(showingFileSearch).allowsHitTesting(!showingFileSearch).accessibilityHidden(showingFileSearch)
    .overlay {
      if showingFileSearch { WorkspaceFileSearchView(workspace: taskWorkspace, open: { path in
        showingReview = false
        showingFiles = true
        taskWorkspace.selectFile(path)
        fileFocusAfterSearch = path
        showingFileSearch = false
      }, cancel: { showingFileSearch = false }) }
    }
    .onChange(of: showingFileSearch) { _, visible in if !visible { restoreFileSearchFocus() } }
    .focusedSceneValue(\.searchDialogActive, showingFileSearch)
    .sheet(item: $previewFile) { FileAttachmentPreview(file: $0, root: store.dataRoot) }
    .disabled(previewImage != nil).allowsHitTesting(previewImage == nil).accessibilityHidden(previewImage != nil)
    .overlay {
      if let image = previewImage {
        ImageGalleryPreview(image: image, images: previewImages, root: store.dataRoot) {
          previewImage = nil
          let returnFocus = imagePreviewReturnFocus
          imagePreviewReturnFocus = nil
          if let returnFocus {
            DispatchQueue.main.async {
              guard previewImage == nil, previewFile == nil, !showingGoalEditor, !showingTaskModelPicker, !showingFileSearch, renameTitle == nil else { return }
              returnFocus()
            }
          } else {
            composerFocused = true
            taskComposerFocusRequest = UUID()
          }
        }.id(image.id)
      }
    }
    .focusedSceneValue(\.imagePreviewActive, previewImage != nil)
    .sheet(isPresented: $showingGoalEditor) {
      GoalEditorView(initial: store.goalSession(for: taskID)?.definition) {
        store.configureGoal($0, taskID: taskID)
      }
    }
    .onAppear {
      mode = store.goalSession(for: taskID)?.status == .active ? .goal : .standard
      configureTaskWorkspace()
    }
    .task(id: taskID) {
      await Task.yield()
      guard !Task.isCancelled else { return }
      composerFocused = true
      taskComposerFocusRequest = UUID()
    }
    .onDisappear {
      terminalSession?.stop()
      store.discardPopoutTaskIfEmpty(taskID)
    }
    .onChange(of: store.library.goalSessions[taskID]) { _, session in
      if session?.status == .active { mode = .goal }
      else if mode == .goal { mode = .standard }
    }
    .onChange(of: store.taskWindowDraft(taskID), initial: true) { _, _ in updateCandidates() }
    .onChange(of: store.enabledComposerCommands) { _, _ in updateCandidates() }
    .onChange(of: store.pluginPreferences) { _, _ in updateCandidates() }
    .onChange(of: store.pluginSkills) { _, _ in updateCandidates() }
    .onChange(of: store.pluginsEnabled) { _, _ in updateCandidates() }
    .task(id: findRevision) {
      guard showingFind else { return }
      await refreshFindMatches()
    }
  }

  private func submitTaskDraft() {
    let command = store.taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines)
    if command == ComposerCommand.files.token {
      guard !windowCommandsBlocked, task?.project.isEmpty == false else { return }
      selectTaskWindowCommand(.files)
    } else if command == ComposerCommand.fork.token {
      forkTask(consumeCommand: true)
    } else {
      Task { await store.sendTaskWindowDraft(taskID, mode: mode) }
    }
  }

  private func forkTask(through runID: String? = nil, consumeCommand: Bool = false) {
    guard !windowCommandsBlocked else { return }
    do {
      let fork = try store.forkTaskWindowConversation(taskID, through: runID, consumeCommand: consumeCommand)
      forkError = nil
      onNavigate(fork.id)
    } catch {
      forkError = error.localizedDescription
      composerFocused = true
      taskComposerFocusRequest = UUID()
      if consumeCommand { commandSelection = ComposerCommandSelection(); updateCandidates() }
    }
  }

  private func openTaskModelPicker() {
    guard !windowCommandsBlocked else { return }
    guard (try? store.modelConfiguration.endpoint("models")) != nil else {
      store.openSettings(.model)
      openWindow(id: "main")
      return
    }
    composerFocused = false
    showingTaskModelPicker = true
  }

  private var windowCommandsBlocked: Bool {
    previewImage != nil || previewFile != nil || showingGoalEditor || showingTaskModelPicker || showingFileSearch || renameTitle != nil || store.restoringLibrary
  }

  private func openTaskFileSearch() {
    guard !windowCommandsBlocked, let task, !task.project.isEmpty else { return }
    configureTaskWorkspace()
    composerFocused = false
    fileFocusAfterSearch = (NSApp.keyWindow?.firstResponder as? FilePreviewTextView)?.workspace === taskWorkspace
      ? taskWorkspace.selectedFile : nil
    showingFileSearch = true
  }

  private func restoreFileSearchFocus() {
    if let path = fileFocusAfterSearch, showingFiles, taskWorkspace.selectedFile == path {
      taskWorkspace.fileFocusRequest = UUID()
    } else {
      composerFocused = true
      taskComposerFocusRequest = UUID()
    }
    fileFocusAfterSearch = nil
  }

  private var windowCommandContext: TaskWindowCommandContext {
    var enabled: Set<String> = windowCommandsBlocked ? [] : ["tab-close"]
    if !windowCommandsBlocked {
      if canGoBack { enabled.insert("back") }
      if canGoForward { enabled.insert("forward") }
    }
    if !windowCommandsBlocked, let task {
      enabled.formUnion(["find", "plan", "model"])
      if store.canForkTaskWindow(taskID) { enabled.insert("fork") }
      if canSend { enabled.insert("send") }
      if store.activeRun(taskID: taskID) != nil { enabled.insert("stop") }
      if !task.isPopoutDraft { enabled.formUnion(["pin", "unread", "rename"]) }
      if !task.isPopoutDraft, !taskRuns.contains(where: \.isActive) { enabled.insert("archive") }
      if showingFind, !finding, !findMatches.isEmpty { enabled.formUnion(["find-next", "find-previous"]) }
      if !task.project.isEmpty { enabled.formUnion(["files", "tree", "review", "review-open", "terminal", "bottom-panel"]) }
      if showingFiles, taskWorkspace.selectedFile != nil, !taskWorkspace.fileLoading,
        taskWorkspace.fileError == nil { enabled.insert("browser-address") }
    }
    return TaskWindowCommandContext(enabled: enabled, perform: performWindowCommand)
  }

  private func performWindowCommand(_ id: String) {
    guard !windowCommandsBlocked else { return }
    if id == "tab-close" { dismiss(); return }
    if id == "back" { if canGoBack { onMove(true) }; return }
    if id == "forward" { if canGoForward { onMove(false) }; return }
    guard let task else { return }
    switch id {
    case "send": if canSend { submitTaskDraft() }
    case "stop": Task { await store.cancel(taskID: taskID) }
    case "find": showingFind = true; findFocusRequest = UUID()
    case "model": openTaskModelPicker()
    case "fork": forkTask()
    case "files": openTaskFileSearch()
    case "rename": composerFocused = false; renameTitle = task.title
    case "find-next": moveFindMatch(1)
    case "find-previous": moveFindMatch(-1)
    case "pin": store.updateTask(taskID, pin: !task.pinned)
    case "unread": store.setTaskUnread(taskID, unread: true)
    case "archive":
      store.updateTask(taskID, archive: true)
      if store.library.tasks.first(where: { $0.id == taskID })?.archived == true { dismiss() }
    case "plan":
      if mode == .goal { store.pauseGoal(taskID) }
      mode = .plan
      composerFocused = true
    case "tree": showingReview = false; showingFiles.toggle()
    case "review": showingFiles = false; showingReview.toggle()
    case "review-open": showingFiles = false; showingReview = true
    case "terminal", "bottom-panel": toggleTerminal(task)
    case "browser-address": taskWorkspace.showingFileLine = true
    default: break
    }
  }

  private func configureTaskWorkspace() {
    guard let task, !task.project.isEmpty else {
      taskWorkspace.setProject(nil)
      showingFiles = false
      showingReview = false
      showingTerminal = false
      return
    }
    let root = URL(fileURLWithPath: task.project).resolvingSymlinksInPath().standardizedFileURL
    if taskWorkspace.root != root { taskWorkspace.setProject(root) }
  }

  private func toggleTerminal(_ task: WorkspaceTask) {
    guard !task.project.isEmpty else { return }
    if terminalSession == nil {
      terminalSession = TerminalSession(root: URL(fileURLWithPath: task.project))
    }
    showingTerminal.toggle()
  }

  private func restartTerminal(_ task: WorkspaceTask) {
    terminalSession?.stop()
    terminalSession = TerminalSession(root: URL(fileURLWithPath: task.project))
    showingTerminal = true
  }

  private var taskTimeline: some View {
    ScrollViewReader { reader in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 28) {
          if let origin = task?.forkOrigin,
            let source = store.library.tasks.first(where: { $0.id == origin.taskID }) {
            Button { onNavigate(source.id) } label: {
              Label("分叉自 \(source.title)", systemImage: "arrow.triangle.branch").lineLimit(2)
            }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
          }
          ForEach(taskRuns) { run in
            TaskWindowMessageView(
              store: store, run: run,
              onPreviewFile: { previewFile = $0 },
              canFork: !windowCommandsBlocked && store.canForkTaskWindow(taskID, through: run.id),
              onFork: { forkTask(through: run.id) }
            ).id(run.id)
          }
          Color.clear.frame(height: 1).id("task-window-end")
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.bottom)
      .onChange(of: taskRuns.map(\.updatedAt)) { _, _ in
        guard !showingFind else { return }
        withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo("task-window-end", anchor: .bottom) }
      }
      .onChange(of: findRequest) { _, _ in findMatch(reader) }
      .onPreferenceChange(ConversationTextAnchors.self) { anchors in
        mountedTexts = anchors
        if let pendingText, anchors.contains(pendingText) {
          reader.scrollTo(pendingText, anchor: .center)
          self.pendingText = nil
        }
      }
      .onPreferenceChange(ConversationOccurrenceAnchors.self) { anchors in
        mountedOccurrences = anchors
        if let pendingMatch, anchors.contains(pendingMatch) {
          reader.scrollTo(pendingMatch, anchor: .center)
          self.pendingMatch = nil
          pendingText = nil
        }
      }
      .overlay {
        if taskRuns.isEmpty {
          ContentUnavailableView(
            "暂无对话内容", systemImage: "bubble.left.and.bubble.right",
            description: Text("在下方输入区继续这个任务。"))
        }
      }
    }
    .environment(
      \.conversationFind,
      ConversationFindContext(query: showingFind ? findText : "", active: activeFindMatch))
  }

  private func refreshFindMatches() async {
    let query = findText
    let inputs = ConversationSearch.inputs(taskRuns, library: store.library)
    let previous = activeFindMatch?.id
    guard !query.isEmpty else {
      findMatches = []
      findIndex = 0
      finding = false
      return
    }
    finding = true
    let matches = await Task.detached(priority: .userInitiated) {
      ConversationSearch.find(inputs, query: query)
    }.value
    guard !Task.isCancelled, showingFind, findText == query else { return }
    findMatches = matches
    finding = false
    if let previous, let index = matches.firstIndex(where: { $0.id == previous }) {
      findIndex = index
    } else {
      findIndex = min(findIndex, max(0, matches.count - 1))
      findRequest = UUID()
    }
  }

  private func moveFindMatch(_ offset: Int) {
    guard !findMatches.isEmpty else { return }
    findIndex = (findIndex + offset + findMatches.count) % findMatches.count
    findRequest = UUID()
  }

  private func closeFind() {
    showingFind = false
    pendingText = nil
    pendingMatch = nil
    composerFocused = true
  }

  private func findMatch(_ reader: ScrollViewProxy) {
    guard let match = activeFindMatch else { return }
    if mountedOccurrences.contains(match.id) {
      pendingText = nil
      pendingMatch = nil
      reader.scrollTo(match.id, anchor: .center)
    } else if mountedTexts.contains(match.textID) {
      pendingText = nil
      pendingMatch = match.id
      reader.scrollTo(match.textID, anchor: .center)
    } else {
      pendingText = match.textID
      pendingMatch = match.id
      reader.scrollTo(match.textID.run, anchor: .top)
    }
  }

  private func taskComposer(_ task: WorkspaceTask) -> some View {
    VStack(spacing: 8) {
      GoalStatusCard(store: store, taskID: taskID) { showingGoalEditor = true }
      TaskWindowBrowserComments(store: store, taskID: taskID)
      if let tip = store.educationalTip(taskID: taskID) {
        ComposerEducationalTipView(
          tip: tip,
          action: {
            if store.performEducationalTip(tip, taskID: taskID) { openWindow(id: "main") }
            else { taskComposerFocusRequest = UUID() }
          },
          dismiss: { store.dismissEducationalTip(tip.id) })
      }
      if commandSelection.isVisible, composerFocused {
        ComposerCommandsView(
          store: store, selection: $commandSelection, enabled: taskWindowCommands
        ) { command in
          selectTaskWindowCommand(command)
        }
      }
      if pluginSelection.isVisible, composerFocused {
        ComposerPluginMentionsView(selection: $pluginSelection) { plugin in
          setDraft(PluginMentionSelection.replacingTrailingMention(in: draft.wrappedValue, plugin: plugin))
        }
      }
      if skillSelection.isVisible, composerFocused {
        ComposerSkillMentionsView(selection: $skillSelection) { skill in
          setDraft(SkillMentionSelection.replacingTrailingMention(in: draft.wrappedValue, skill: skill))
        }
      }
      if let error = store.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button {
            store.error = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).help("关闭提示")
        }
        .appFont(.caption).padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      }
      if task.project != store.currentProjectKey {
        HStack {
          Label("主窗口当前位于其他项目；模型会话仍可独立继续", systemImage: "rectangle.on.rectangle")
          Spacer()
          Button("在主窗口中打开") {
            store.selectTask(task)
            openWindow(id: "main")
          }
        }
        .appFont(.caption).foregroundStyle(.secondary)
      }
      ImageAttachmentsView(
        store: store, images: store.taskWindowImages(taskID), removable: true,
        onRemove: { store.removeDraftImage($0, draft: taskID) })
      FileAttachmentsView(
        store: store, files: store.taskWindowFiles(taskID), removable: true,
        onPreview: { previewFile = $0 },
        onRemove: { store.removeDraftFile($0, draft: taskID) })
      HStack(alignment: .bottom, spacing: 10) {
        Menu {
          Button("添加文件…", systemImage: "doc.badge.plus") {
            store.chooseFiles(draft: taskID)
          }.disabled(store.taskWindowFiles(taskID).count >= FileAttachmentStorage.maxCount)
          Button("添加图片…", systemImage: "photo") {
            store.chooseImages(draft: taskID)
          }.disabled(store.taskWindowImages(taskID).count >= ImageAttachmentStorage.maxCount)
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize().help("添加文件或图片，也可拖入输入区")
        .accessibilityLabel("任务窗口添加附件")
        .disabled(store.importingImages || store.importingFiles)

        Menu {
          Button("模型会话", systemImage: ChatMode.standard.icon) {
            if mode == .goal { store.pauseGoal(taskID) }
            mode = .standard
          }
          Button("计划模式", systemImage: ChatMode.plan.icon) {
            if mode == .goal { store.pauseGoal(taskID) }
            mode = .plan
          }
          Button("目标模式…", systemImage: ChatMode.goal.icon) { showingGoalEditor = true }
        } label: {
          Image(systemName: mode.icon)
        }
        .menuStyle(.borderlessButton).fixedSize().help(mode.title)

        ComposerTextEditor(
          text: draft,
          focused: Binding(get: { composerFocused }, set: { composerFocused = $0 }),
          plainTextMode: store.composerPlainTextMode,
          placeholder: "继续这个任务…",
          accessibilityLabel: "任务窗口输入",
          focusRequest: taskComposerFocusRequest,
          onKey: handleCandidateKey,
          onPasteAttachments: { store.pasteAttachments($0, draft: taskID) }
        ).frame(minHeight: 42, maxHeight: 118)

        if store.taskWindowOwnsActiveRun(taskID) {
          Button {
            Task { await store.cancel(taskID: taskID) }
          } label: {
            Image(systemName: "stop.fill").frame(width: 28, height: 28)
          }
          .buttonStyle(.bordered).clipShape(Circle()).help("停止任务")
        } else {
          Button {
            submitTaskDraft()
          } label: {
            Image(systemName: "arrow.up")
              .foregroundStyle(Color(nsColor: .windowBackgroundColor))
              .frame(width: 28, height: 28).background(Color.primary, in: Circle())
          }
          .buttonStyle(.plain).disabled(!canSend).help("发送消息 " + store.shortcuts.label("send"))

        }
      }
      .padding(14)
      .background(.background, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
      HStack {
        Button(store.modelConfiguration(for: taskID).model.isEmpty ? "配置模型…" : store.modelConfiguration(for: taskID).model) {
          openTaskModelPicker()
        }.buttonStyle(.plain).help("选择模型与推理强度 " + store.shortcuts.label("model"))
          .popover(isPresented: $showingTaskModelPicker, arrowEdge: .top) {
            ComposerModelPicker(store: store, taskID: taskID,
              onClose: { showingTaskModelPicker = false },
              onSettings: {
                showingTaskModelPicker = false
                store.openSettings(.model)
                openWindow(id: "main")
              })
          }
          .onChange(of: showingTaskModelPicker) { _, presented in
            if !presented { composerFocused = true; taskComposerFocusRequest = UUID() }
          }
        Spacer()
        if store.showContextUsageIndicator, let tokens = store.contextInputTokens(taskID: taskID) {
          Label(tokens.formatted() + " tokens", systemImage: "gauge.with.dots.needle.33percent")
            .help("最近一轮请求使用的上下文输入 token")
        }
        Text(mode.title)
      }.appFont(size: 10).foregroundStyle(.secondary).padding(.horizontal, 4)
    }
    .frame(maxWidth: 780).padding(.horizontal, 24).padding(.vertical, 12)
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !store.importingImages, !store.importingFiles else { return false }
      Task { await store.importDroppedFiles(urls, draft: taskID) }
      return true
    } isTargeted: { dropTargeted = $0 }
    .overlay {
      if dropTargeted {
        RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
  }

  private var taskWindowCommands: Set<ComposerCommand> {
    guard let task else { return [] }
    return Set(ComposerCommand.allCases.filter { command in
      if command == .fork { return store.canForkTaskWindow(taskID) }
      if task.project.isEmpty {
        return ![.doctor, .build, .review, .files, .terminal].contains(command)
      }
      return true
    })
  }

  private var sendShortcut: ComposerSendShortcut {
    if UserDefaults.standard.object(forKey: ComposerSendShortcut.storageKey) == nil {
      return ComposerSendShortcut.stored()
    }
    return ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func setDraft(_ value: String) {
    store.setTaskWindowDraft(value, taskID: taskID)
    updateCandidates()
  }

  private func updateCandidates() {
    let value = store.taskWindowDraft(taskID)
    commandSelection.update(
      draft: value, enabled: taskWindowCommands)
    pluginSelection.update(draft: value, plugins: store.composerPlugins)
    skillSelection.update(draft: value, skills: store.composerSkills)
  }

  private func selectTaskWindowCommand(_ command: ComposerCommand) {
    switch command {
    case .fork:
      forkTask(consumeCommand: true)
      return
    case .chat:
      if mode == .goal { store.pauseGoal(taskID) }
      mode = .standard
      setDraft("")
    case .plan:
      if mode == .goal { store.pauseGoal(taskID) }
      mode = .plan
      setDraft("")
    case .goal:
      setDraft("")
      showingGoalEditor = true
    case .model, .reasoning:
      setDraft("")
      openTaskModelPicker()
    case .files:
      setDraft("")
      openTaskFileSearch()
    default:
      guard let task else { return }
      setDraft("")
      Task {
        guard await store.openTaskScope(task.project) else { return }
        store.applyTaskSelection(task)
        store.selectComposerCommand(command)
        openWindow(id: "main")
      }
    }
    composerFocused = command == .chat || command == .plan || command == .goal
  }

  private func handleCandidateKey(
    _ key: ComposerEditorKey, _ modifiers: NSEvent.ModifierFlags, _ composing: Bool
  ) -> Bool {
    guard !composing else { return false }
    if modifiers.isEmpty {
      updateCandidates()
    let menuKey: ComposerCommandSelection.Key
    switch key {
    case .up: menuKey = .previous
    case .down: menuKey = .next
    case .escape: menuKey = .dismiss
    default: menuKey = .accept
    }
    switch commandSelection.handle(menuKey) {
    case .accept(let command):
      selectTaskWindowCommand(command)
      return true
    case .handled: return true
    case .ignored: break
    }
    let mentionKey: PluginMentionSelection.Key
    switch key {
    case .up: mentionKey = .previous
    case .down: mentionKey = .next
    case .escape: mentionKey = .dismiss
    default: mentionKey = .accept
    }
    switch pluginSelection.handle(mentionKey, isComposing: false) {
    case .accept(let plugin):
      setDraft(PluginMentionSelection.replacingTrailingMention(in: draft.wrappedValue, plugin: plugin))
      return true
    case .handled: return true
    case .ignored: break
    }
    let skillKey: SkillMentionSelection.Key
    switch key {
    case .up: skillKey = .previous
    case .down: skillKey = .next
    case .escape: skillKey = .dismiss
    default: skillKey = .accept
    }
    switch skillSelection.handle(skillKey, isComposing: false) {
    case .accept(let skill):
      setDraft(SkillMentionSelection.replacingTrailingMention(in: draft.wrappedValue, skill: skill))
      return true
    case .handled: return true
    case .ignored: break
    }
    if key == .up, draft.wrappedValue.isEmpty {
      store.restoreTaskWindowPrompt(taskID)
      return true
    }
    if key == .enter, sendShortcut.sendsOnPlainReturn(draft.wrappedValue) {
      if canSend { submitTaskDraft() }
      return true
    }
    }
    if key == .enter, modifiers == .command, store.shortcuts.matches("send", ShortcutBinding("⌘↵")) {
      if canSend { submitTaskDraft() }
      return true
    }
    return false
  }
}

private struct TaskWindowMessageView: View {
  @Bindable var store: WorkspaceStore
  let run: AgentRun
  let onPreviewFile: (FileAttachment) -> Void
  let canFork: Bool
  let onFork: () -> Void
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      FileAttachmentsView(
        store: store, files: store.library.runFiles[run.id] ?? [], onPreview: onPreviewFile)
      ImageAttachmentsView(
        store: store, images: store.library.runImages[run.id] ?? [])
      if let prompt = store.library.notes[run.id], !prompt.isEmpty {
        HStack {
          Spacer(minLength: 36)
          ConversationSearchText(prompt, id: .init(run: run.id, part: "prompt"))
            .textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 11)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
        }
      }
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "sparkle")
          Text("ShipiOS").appFont(.caption, weight: .semibold)
          Text(run.kind == "chat" ? (run.request["model"].text ?? "模型") : "本地执行")
            .appFont(.caption).foregroundStyle(.tertiary)
          Spacer()
          StatusLabel(run: run).appFont(.caption)
        }
        if run.kind == "chat" {
          if run.request["mode"].text == ChatMode.goal.rawValue {
            Label(
              "目标执行 · 第 \(run.request["goal_iteration"].int ?? 1)/\(run.request["goal_max_iterations"].int ?? 1) 轮",
              systemImage: ChatMode.goal.icon
            ).appFont(.caption, weight: .medium).foregroundStyle(.secondary)
          }
          ChatResponseView(store: store, run: run)
          if run.isActive { ProgressView().controlSize(.small) }
          if let message = run.result?["message"].text {
            Text(message).foregroundStyle(.red).textSelection(.enabled)
          }
        } else {
          ConversationSearchText(run.title, id: .init(run: run.id, part: "operation"))
            .appFont(.callout, weight: .semibold)
          ConversationSearchText(run.displaySummary, id: .init(run: run.id, part: "summary"))
            .textSelection(.enabled)
        }
        if !run.isActive {
          HStack(spacing: 12) {
            Button {
              let text = run.kind == "chat" ? (run.result?["response"].text ?? "") : run.displaySummary
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(text, forType: .string)
              copied = true
            } label: {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(copied ? "已复制" : "复制结果")
            Button(action: onFork) { Image(systemName: "arrow.triangle.branch") }
              .buttonStyle(.plain).foregroundStyle(.secondary).disabled(!canFork)
              .help("从此处分叉到新任务").accessibilityLabel("从此处分叉到新任务")
          }
        }
      }
    }
    .task(id: copied) {
      guard copied else { return }
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled { copied = false }
    }
  }
}

private struct TaskWindowFindBar: View {
  @Binding var text: String
  let count: Int
  let index: Int
  let finding: Bool
  let focusRequest: UUID
  let shortcuts: ShortcutPreferences
  let previous: () -> Void
  let next: () -> Void
  let close: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
      TextField("在当前任务中查找", text: $text)
        .textFieldStyle(.roundedBorder).focused($focused).onSubmit(next)
      Text(count == 0 ? "0 项" : "\(min(index + 1, count)) / \(count)")
        .appFont(.caption).foregroundStyle(.secondary)
      if finding { ProgressView().controlSize(.mini).accessibilityLabel("正在查找") }
      Button(action: previous) { Image(systemName: "chevron.up") }
        .buttonStyle(.plain).disabled(count == 0).help("上一个匹配 " + shortcuts.label("find-previous"))
        .accessibilityLabel("上一个匹配")
      Button(action: next) { Image(systemName: "chevron.down") }
        .buttonStyle(.plain).disabled(count == 0).help("下一个匹配 " + shortcuts.label("find-next"))
        .accessibilityLabel("下一个匹配")
      Button(action: close) { Image(systemName: "xmark") }
        .buttonStyle(.plain).help("关闭查找").accessibilityLabel("关闭查找")
    }
    .padding(10)
    .task(id: focusRequest) {
      focused = false
      await Task.yield()
      guard !Task.isCancelled else { return }
      focused = true
    }
    .onExitCommand(perform: close)
  }
}

private struct TaskWindowFilesPanel: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("文件", systemImage: "doc").appFont(.caption, weight: .medium)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("隐藏任务文件").accessibilityLabel("隐藏任务文件")
      }.padding(10)
      Divider()
      FileWorkspaceView(store: store, workspace: workspace)
    }
  }
}

private struct TaskWindowReviewPanel: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let taskID: String
  let close: () -> Void
  let focusComposer: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("审查", systemImage: "square.stack.3d.up").appFont(.caption, weight: .medium)
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("隐藏任务审查").accessibilityLabel("隐藏任务审查")
      }.padding(10)
      Divider()
      GitReviewView(
        store: store, workspace: workspace, taskID: taskID, focusComposer: focusComposer)
    }
  }
}

private struct TaskWindowTerminalPanel: View {
  @Bindable var session: TerminalSession
  let task: WorkspaceTask
  let hide: () -> Void
  let restart: () -> Void
  @State private var focus: TerminalFocusRequest?

  private var scope: TerminalScope {
    TerminalScope(root: session.root, conversation: task.id)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("终端", systemImage: "terminal").appFont(.caption, weight: .medium)
        Text(task.title).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Text(session.title).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        if session.status == .running {
          Button { session.stop() } label: { Image(systemName: "stop") }
            .buttonStyle(.plain).help("结束此窗口的终端会话").accessibilityLabel("结束终端会话")
        }
        Button(action: restart) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).help("重新打开终端").accessibilityLabel("重新打开终端")
        Button(action: hide) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("隐藏终端，保留会话").accessibilityLabel("隐藏任务终端")
      }.padding(10)
      Divider()
      TerminalHost(session: session, focus: focus) { request in
        focus == request
      }
      if session.status != .running {
        HStack {
          Text(session.status.label).appFont(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("重新打开", action: restart).controlSize(.small)
        }.padding(.horizontal, 10).padding(.vertical, 6)
      }
    }
    .onAppear { focus = TerminalFocusRequest(scope: scope) }
  }
}
