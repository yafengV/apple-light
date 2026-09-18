import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
  @Bindable var store: WorkspaceStore
  @State private var imageDropTargeted = false
  @State private var showingBuildOptions = false
  @State private var commandSelection = ComposerCommandSelection()
  @State private var pluginSelection = PluginMentionSelection()
  @State private var skillSelection = SkillMentionSelection()
  @State private var focused = false
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue

  var body: some View {
    VStack(spacing: 9) {
      GoalStatusCard(store: store, taskID: store.selectedTask?.id) {
        store.showingGoalEditor = true
      }
      ComposerQueueView(store: store)
      ComposerReviewComments(store: store)
      ComposerBrowserComments(store: store)
      if let tip = store.educationalTip(taskID: store.selectedTask?.id) {
        ComposerEducationalTipView(
          tip: tip,
          action: { store.performEducationalTip(tip, taskID: nil) },
          dismiss: { store.dismissEducationalTip(tip.id) })
      }
      if store.showingReviewMode, store.destination == .workspace {
        ComposerReviewModeView(store: store)
      } else if commandSelection.isVisible, focused, store.destination == .workspace {
        ComposerCommandsView(store: store, selection: $commandSelection)
      }
      if pluginSelection.isVisible, focused, store.destination == .workspace {
        ComposerPluginMentionsView(selection: $pluginSelection) { plugin in
          store.draft = PluginMentionSelection.replacingTrailingMention(
            in: store.draft, plugin: plugin)
        }
      }
      if skillSelection.isVisible, focused, store.destination == .workspace {
        ComposerSkillMentionsView(selection: $skillSelection) { skill in
          store.draft = SkillMentionSelection.replacingTrailingMention(
            in: store.draft, skill: skill)
        }
      }
      if let active = store.selectedActiveRun {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(active.title).appFont(.caption).foregroundStyle(.secondary)
          Spacer()
          if !store.conversationRuns.contains(where: { $0.id == active.id }) {
            Button("查看运行中的任务") { store.selection = active.id }.buttonStyle(.plain).appFont(.caption)
          }
        }.padding(.horizontal, 4)
      }
      VStack(alignment: .leading, spacing: 12) {
        ImageAttachmentsView(store: store, images: store.draftImages, removable: true)
        FileAttachmentsView(store: store, files: store.draftFiles, removable: true)
        if store.importingFiles { ProgressView("正在添加文件…").controlSize(.small).appFont(.caption) }
        if store.importingImages {
          ProgressView("正在添加图片…").controlSize(.small).appFont(.caption)
        }
        editor
        controls
      }.padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
          RoundedRectangle(cornerRadius: 18).strokeBorder(
            Color.primary.opacity(focused ? 0.23 : 0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
      HStack {
        Label(
          store.action == .chat ? "独立 API" : "本地执行",
          systemImage: store.action == .chat ? "network" : "desktopcomputer")
        if store.action != .chat { Text("· 说明保存在本机") }
        Spacer()
        Text("\(store.shortcuts.label("send")) 执行").foregroundStyle(.tertiary)
      }.appFont(size: 10).foregroundStyle(.secondary).padding(.horizontal, 4)
    }
    .frame(maxWidth: 780)
    .dropDestination(for: URL.self) { urls, _ in
      guard store.destination == .workspace, !store.importingImages, !store.importingFiles, !urls.isEmpty else { return false }
      let key = store.draftKey
      Task { await store.importDroppedFiles(urls, draft: key) }
      return true
    } isTargeted: { imageDropTargeted = $0 }
    .overlay {
      if imageDropTargeted {
        RoundedRectangle(cornerRadius: 18).strokeBorder(.tint, lineWidth: 2)
          .allowsHitTesting(false)
      }
    }
    .onChange(of: store.draft, initial: true) { _, _ in updateCommands() }
    .onChange(of: store.enabledComposerCommands) { _, _ in updateCommands() }
    .onChange(of: store.pluginPreferences) { _, _ in updateCommands() }
    .onChange(of: store.pluginSkills) { _, _ in updateCommands() }
    .onChange(of: store.pluginsEnabled) { _, _ in updateCommands() }
    .onChange(of: store.draftKey) { _, _ in
      commandSelection = ComposerCommandSelection()
      pluginSelection = PluginMentionSelection()
      skillSelection = SkillMentionSelection()
      updateCommands()
    }
    .onChange(of: store.focusComposer) { _, _ in focused = true }
    .onChange(of: store.blurComposer) { _, _ in focused = false }
    .onChange(of: store.showingModelPicker) { _, showing in
      if !showing, store.destination == .workspace { focused = true }
    }
    .onChange(of: store.action) { _, action in
      if action != .chat {
        if store.chatMode == .goal { store.leaveGoalMode() }
        store.chatMode = .standard
        store.showingModelPicker = false
      }
    }
    .onChange(of: store.destination) { _, destination in
      if destination != .workspace {
        store.showingModelPicker = false
        store.dismissCodeReviewMode()
        showingBuildOptions = false
        focused = false
      }
    }
    .onChange(of: store.container) { _, _ in store.saveProfile() }
    .onChange(of: store.scheme) { _, _ in store.saveProfile() }
    .onChange(of: store.configuration) { _, _ in store.saveProfile() }
    .sheet(isPresented: $store.showingGoalEditor) {
      GoalEditorView(initial: store.composerGoalDefinition) { store.configureGoal($0) }
    }
  }
  private var editor: some View {
    ComposerTextEditor(
      text: $store.draft,
      focused: Binding(get: { focused }, set: { focused = $0 }),
      plainTextMode: store.composerPlainTextMode,
      placeholder: "发送消息，或输入 / 选择操作…",
      accessibilityLabel: "任务输入",
      focusRequest: store.focusComposer,
      onKey: handleEditorKey,
      onPasteAttachments: { store.pasteAttachments($0) }
    )
    .frame(minHeight: 50, maxHeight: 118)
  }
  private func handleEditorKey(
    _ key: ComposerEditorKey, _ modifiers: NSEvent.ModifierFlags, _ composing: Bool
  ) -> Bool {
    guard store.destination == .workspace, !composing else { return false }
    if modifiers.isEmpty {
        updateCommands()
        let menuKey: ComposerCommandSelection.Key
        switch key {
        case .up: menuKey = .previous
        case .down: menuKey = .next
        case .escape: menuKey = .dismiss
        default: menuKey = .accept
        }
        switch commandSelection.handle(menuKey) {
        case .accept(let command):
          store.selectComposerCommand(command)
          return true
        case .handled: return true
        case .ignored: break
        }
        let pluginKey: PluginMentionSelection.Key
        switch key {
        case .up: pluginKey = .previous
        case .down: pluginKey = .next
        case .escape: pluginKey = .dismiss
        default: pluginKey = .accept
        }
        switch pluginSelection.handle(pluginKey, isComposing: false) {
        case .accept(let plugin):
          store.draft = PluginMentionSelection.replacingTrailingMention(
            in: store.draft, plugin: plugin)
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
          store.draft = SkillMentionSelection.replacingTrailingMention(
            in: store.draft, skill: skill)
          return true
        case .handled: return true
        case .ignored: break
        }
        if key == .up, store.draft.isEmpty {
          store.restorePrompt()
          return true
        }
        if key == .enter, sendShortcut.sendsOnPlainReturn(store.draft) {
          if store.canSend { Task { await store.sendDraft() } }
          return true
        }
    }
    if key == .enter, modifiers == .command {
      if store.canSend { Task { await store.sendDraft() } }
      return true
    }
    return false
  }
  private var sendShortcut: ComposerSendShortcut {
    if UserDefaults.standard.object(forKey: ComposerSendShortcut.storageKey) == nil {
      return ComposerSendShortcut.stored()
    }
    return ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }
  private func updateCommands() {
    commandSelection.update(draft: store.draft, enabled: store.enabledComposerCommands)
    pluginSelection.update(
      draft: store.draft, plugins: store.composerPlugins)
    skillSelection.update(
      draft: store.draft, skills: store.composerSkills)
  }
  private var controls: some View {
    HStack(spacing: 10) {
      Menu {
        Button("添加文件…", systemImage: "doc.badge.plus") { store.chooseFiles() }
          .disabled(store.draftFiles.count >= FileAttachmentStorage.maxCount)
        Button("添加图片…", systemImage: "photo") { store.chooseImages() }
          .disabled(store.draftImages.count >= ImageAttachmentStorage.maxCount)
      } label: { Image(systemName: "plus") }
        .menuStyle(.borderlessButton).fixedSize().help("添加文件或图片，也可拖入输入区")
        .accessibilityLabel("添加附件")
        .disabled(store.importingImages || store.importingFiles)
      Menu {
        ForEach(LocalAction.allCases) { action in
          Button(action.title, systemImage: action.icon) {
            if store.chatMode == .goal { store.leaveGoalMode() }
            store.action = action
            store.chatMode = .standard
          }
            .disabled(action != .chat && (store.project == nil || !store.draftImages.isEmpty || !store.draftFiles.isEmpty))
        }
        Divider()
        Button("计划模式", systemImage: ChatMode.plan.icon) {
          if store.chatMode == .goal { store.leaveGoalMode() }
          store.action = .chat
          store.chatMode = .plan
        }
        Button("目标模式…", systemImage: ChatMode.goal.icon) {
          store.action = .chat
          store.showingGoalEditor = true
        }
      } label: {
        Label(
          store.action == .chat && store.chatMode != .standard ? store.chatMode.title : store.action.title,
          systemImage: store.action == .chat && store.chatMode != .standard
            ? store.chatMode.icon : store.action.icon
        ).appFont(.caption)
      }.menuStyle(.borderlessButton).fixedSize()
      if store.action == .chat, store.chatMode != .standard {
        Button {
          if store.chatMode == .goal { store.leaveGoalMode() } else { store.chatMode = .standard }
        } label: {
          Label(store.chatMode == .goal ? "暂停目标" : "退出计划", systemImage: "xmark")
            .labelStyle(.iconOnly)
        }.buttonStyle(.plain).foregroundStyle(.secondary)
          .help(store.chatMode == .goal ? "暂停目标模式" : "退出计划模式")
          .accessibilityLabel(store.chatMode == .goal ? "暂停目标模式" : "退出计划模式")
      }
      if store.action == .chat {
        Button(store.modelConfiguration(for: store.selectedTask?.id).model.isEmpty ? "配置模型…" : store.modelConfiguration(for: store.selectedTask?.id).model) {
          store.openModelPicker()
        }.buttonStyle(.plain).appFont(.caption).lineLimit(1).help(
          "选择模型与推理强度 \(store.shortcuts.label("model"))")
          .popover(isPresented: $store.showingModelPicker, arrowEdge: .top) {
            ComposerModelPicker(store: store, taskID: store.selectedTask?.id)
          }
      }
      if store.action == .build {
        Button {
          showingBuildOptions.toggle()
        } label: {
          HStack(spacing: 4) {
            Text(store.scheme.isEmpty ? "配置构建" : store.scheme).lineLimit(1)
            Image(systemName: "chevron.down").appFont(size: 8)
          }.appFont(.caption)
        }.buttonStyle(.plain).foregroundStyle(.secondary).help("工程、Scheme 与构建配置")
          .popover(isPresented: $showingBuildOptions, arrowEdge: .top) {
            BuildOptionsView(store: store).padding(20).frame(width: 360)
          }
      }
      Spacer(minLength: 8)
      if store.showContextUsageIndicator,
        let tokens = store.contextInputTokens(taskID: store.selectedTask?.id)
      {
        Label(tokens.formatted() + " tokens", systemImage: "gauge.with.dots.needle.33percent")
          .appFont(.caption).foregroundStyle(.secondary)
          .help("最近一轮请求使用的上下文输入 token")
      }
      if store.selectedActiveRun?.kind == "chat", store.canSend, !store.draft.isEmpty || !store.draftImages.isEmpty || !store.draftFiles.isEmpty {
        Button(store.followUpBehavior.composerLabel) { Task { await store.sendDraft() } }
          .buttonStyle(.bordered).controlSize(.small).help(store.followUpBehavior.explanation)
      }
      if store.selectedActiveRun != nil {
        Button {
          Task { await store.cancel() }
        } label: {
          Image(systemName: "stop.fill").appFont(size: 12, weight: .semibold).frame(
            width: 30, height: 30)
        }.buttonStyle(.bordered).clipShape(Circle()).help("停止任务 \(store.shortcuts.label("stop"))")
          .accessibilityLabel("停止任务")
      } else {
        Button {
          Task { await store.sendDraft() }
        } label: {
          Image(systemName: "arrow.up").appFont(size: 15, weight: .semibold)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .frame(width: 30, height: 30).background(Color.primary, in: Circle())
        }.buttonStyle(.plain).disabled(!store.canSend)
          .help("执行选定操作 \(store.shortcuts.label("send"))").accessibilityLabel("发送任务")
      }
    }
  }

}

struct BuildOptionsView: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("构建配置").appFont(.headline)
      VStack(alignment: .leading, spacing: 6) {
        Text("Xcode 工程").appFont(.caption).foregroundStyle(.secondary)
        Picker("工程", selection: $store.container) {
          if store.inspection?.containers.isEmpty != false { Text("未发现工程").tag("") }
          ForEach(store.inspection?.containers ?? [], id: \.self) { Text($0).tag($0) }
        }.labelsHidden()
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("共享 Scheme").appFont(.caption).foregroundStyle(.secondary)
        TextField("例如 HelloShipiOS", text: $store.scheme).textFieldStyle(.roundedBorder)
          .accessibilityLabel("Scheme")
      }
      Picker("配置", selection: $store.configuration) {
        Text("Debug").tag("Debug")
        Text("Release").tag("Release")
      }
      Divider()
      Label("iOS Simulator SDK", systemImage: "iphone").appFont(.caption)
      Text("仅编译，不启动模拟器。运行项目中定义的构建脚本。")
        .appFont(.caption).foregroundStyle(.secondary)
    }.disabled(store.busy || store.activeLocalRun != nil)
  }
}
