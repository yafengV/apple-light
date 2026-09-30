import AppKit
import SwiftUI

struct PopoutHomeView: View {
  @Bindable var store: WorkspaceStore
  let onSubmit: (String, Bool) -> Bool
  let onOpenThread: (String) -> Void
  let onHide: () -> Void
  @State private var projectless: Bool
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var previewFile: FileAttachment?
  @State private var previewImage: ImagePreviewItem?
  @State private var previewImages: [ImagePreviewItem] = []
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

  init(store: WorkspaceStore, onSubmit: @escaping (String, Bool) -> Bool,
    onOpenThread: @escaping (String) -> Void, onHide: @escaping () -> Void) {
    self.store = store
    self.onSubmit = onSubmit
    self.onOpenThread = onOpenThread
    self.onHide = onHide
    _projectless = State(initialValue: store.popoutWindowProjectlessDefault)
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
        placeholder: "发送消息，或输入 / 选择操作…",
        accessibilityLabel: "弹出窗口消息", focusRequest: focusRequest,
        onKey: { key, modifiers, composing in
          if handleSlashKey(key, modifiers: modifiers, composing: composing) { return true }
          guard shouldSubmit(key, modifiers: modifiers, composing: composing,
            text: draft.wrappedValue, shortcut: sendShortcut, store: store) else { return false }
          submit()
          return true
        }, onPasteAttachments: { store.pasteAttachments($0, draft: WorkspaceStore.popoutHomeDraftKey) })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let error = store.generalSettingsError {
        Text(error).appFont(.caption).foregroundStyle(.red)
      }
      if let error = store.error {
        Text(error).appFont(.caption).foregroundStyle(.red)
      }
      HStack(spacing: 12) {
        Menu {
          Button("添加图片…") { store.chooseImages(draft: WorkspaceStore.popoutHomeDraftKey) }
          Button("添加文件…") { store.chooseFiles(draft: WorkspaceStore.popoutHomeDraftKey) }
        } label: { Image(systemName: "plus") }
          .menuStyle(.borderlessButton).accessibilityLabel("添加弹出窗口附件")
        Toggle("独立聊天", isOn: $projectless)
          .toggleStyle(.checkbox)
          .help("在任何项目外开始新聊天")
        if !projectless, !store.currentProjectKey.isEmpty {
          Text(store.library.projectTitle(store.currentProjectKey))
            .lineLimit(1).appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("发送", action: submit)
          .buttonStyle(.borderedProminent)
          .disabled(!hasContent || !store.libraryLoaded || store.importingImages || store.importingFiles)
      }
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
    .onChange(of: store.popoutWindowProjectlessDefault) { _, value in
      if store.popoutHomeDraft.isEmpty { projectless = value }
    }
    .environment(\.presentImageGallery) { image, images, _ in
      previewImage = image
      previewImages = images
    }
    .sheet(item: $previewFile) { FileAttachmentPreview(file: $0, root: store.dataRoot) }
    .sheet(item: $previewImage) { image in
      ImageGalleryPreview(image: image, images: previewImages, root: store.dataRoot) {
        previewImage = nil
      }.frame(width: 720, height: 520)
    }
    .onExitCommand {
      if slashSelection.isVisible { _ = slashSelection.handle(.dismiss) }
      else { onHide() }
    }
  }

  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func submit() {
    guard store.libraryLoaded, !store.importingImages, !store.importingFiles, hasContent else { return }
    _ = onSubmit(draft.wrappedValue, projectless)
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
  let onHide: () -> Void
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var slashSelection = PopoutSlashSelection()
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue
  private var runs: [AgentRun] { store.taskWindowRuns(taskID) }
  private var task: WorkspaceTask? { store.library.tasks.first { $0.id == taskID } }
  private var queuedCount: Int {
    store.library.queuedMessages.filter { $0.taskID == taskID }.count
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

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button { onHome() } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).accessibilityLabel("返回弹出窗口首页")
        Text(task?.title ?? "会话").lineLimit(1).appFont(size: 14, weight: .semibold)
        Spacer()
        Button { onHide() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("隐藏弹出窗口")
      }.padding(.horizontal, 18).padding(.vertical, 14)
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 25) {
            ForEach(runs) { run in
              ExecutionMessageView(store: store, run: run).id(run.id)
            }
            Color.clear.frame(height: 1).id("end")
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: runs.map(\.id)) { _, _ in reader.scrollTo("end", anchor: .bottom) }
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
        VStack(alignment: .leading, spacing: 6) {
          ImageAttachmentsView(store: store, images: store.taskWindowImages(taskID), removable: true)
          FileAttachmentsView(store: store, files: store.taskWindowFiles(taskID), removable: true)
        }.padding(.horizontal, 14).padding(.top, 10)
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
    .onExitCommand {
      if slashSelection.isVisible { _ = slashSelection.handle(.dismiss) }
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
