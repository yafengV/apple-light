import AppKit
import SwiftUI

struct PopoutHomeView: View {
  @Bindable var store: WorkspaceStore
  let onSubmit: (String, Bool) -> Bool
  let onHide: () -> Void
  @State private var draft = ""
  @State private var projectless: Bool
  @State private var focused = false
  @State private var focusRequest = UUID()
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue

  init(store: WorkspaceStore, onSubmit: @escaping (String, Bool) -> Bool,
    onHide: @escaping () -> Void) {
    self.store = store
    self.onSubmit = onSubmit
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
      ComposerTextEditor(text: $draft,
        focused: $focused, plainTextMode: store.composerPlainTextMode,
        placeholder: "发送消息，或输入 / 选择操作…",
        accessibilityLabel: "弹出窗口消息", focusRequest: focusRequest,
        onKey: { key, modifiers, composing in
          guard shouldSubmit(key, modifiers: modifiers, composing: composing,
            text: draft, shortcut: sendShortcut, store: store) else { return false }
          submit()
          return true
        }, onPasteAttachments: { _ in })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let error = store.generalSettingsError {
        Text(error).appFont(.caption).foregroundStyle(.red)
      }
      HStack(spacing: 12) {
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
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.libraryLoaded)
      }
    }
    .padding(20)
    .frame(minWidth: 400, minHeight: 250)
    .background(store.appearance.backgroundColor)
    .foregroundStyle(store.appearance.foregroundColor)
    .tint(store.appearance.accentColor)
    .preferredColorScheme(store.appearance.colorScheme)
    .onAppear { focused = true; focusRequest = UUID() }
    .onChange(of: store.popoutWindowProjectlessDefault) { _, value in
      if draft.isEmpty { projectless = value }
    }
    .onExitCommand(perform: onHide)
  }

  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func submit() {
    if onSubmit(draft, projectless) { draft = "" }
  }
}

struct PopoutThreadView: View {
  @Bindable var store: WorkspaceStore
  let taskID: String
  let onHome: () -> Void
  let onHide: () -> Void
  @State private var focused = false
  @State private var focusRequest = UUID()
  @AppStorage(ComposerSendShortcut.storageKey) private var sendShortcutRaw =
    ComposerSendShortcut.commandEnter.rawValue
  private var runs: [AgentRun] { store.taskWindowRuns(taskID) }
  private var task: WorkspaceTask? { store.library.tasks.first { $0.id == taskID } }
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
      if !store.taskWindowImages(taskID).isEmpty || !store.taskWindowFiles(taskID).isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ImageAttachmentsView(store: store, images: store.taskWindowImages(taskID), removable: true)
          FileAttachmentsView(store: store, files: store.taskWindowFiles(taskID), removable: true)
        }.padding(.horizontal, 14).padding(.top, 10)
      }
      HStack(alignment: .bottom, spacing: 8) {
        Menu {
          Button("添加图片…") { store.chooseImages(draft: taskID) }
          Button("添加文件…") { store.chooseFiles(draft: taskID) }
        } label: { Image(systemName: "plus") }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("添加弹出会话附件")
        ComposerTextEditor(text: draft,
          focused: $focused, plainTextMode: store.composerPlainTextMode,
          placeholder: "继续这个任务…", accessibilityLabel: "弹出会话消息",
          focusRequest: focusRequest,
          onKey: { key, modifiers, composing in
            guard shouldSubmit(key, modifiers: modifiers, composing: composing,
              text: draft.wrappedValue, shortcut: sendShortcut, store: store) else { return false }
            submit()
            return true
          }, onPasteAttachments: { store.pasteAttachments($0, draft: taskID) })
          .frame(minHeight: 48, maxHeight: 90)
        Button {
          submit()
        } label: { Image(systemName: "arrow.up") }
          .buttonStyle(.borderedProminent)
          .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.taskWindowImages(taskID).isEmpty && store.taskWindowFiles(taskID).isEmpty)
          .accessibilityLabel("发送弹出会话消息")
      }.padding(14)
    }
    .frame(minWidth: 400, minHeight: 400)
    .background(store.appearance.backgroundColor)
    .foregroundStyle(store.appearance.foregroundColor)
    .tint(store.appearance.accentColor)
    .preferredColorScheme(store.appearance.colorScheme)
    .onAppear { focused = true; focusRequest = UUID() }
    .onExitCommand(perform: onHide)
  }

  private var sendShortcut: ComposerSendShortcut {
    ComposerSendShortcut(rawValue: sendShortcutRaw) ?? .commandEnter
  }

  private func submit() {
    Task { await store.sendTaskWindowDraft(taskID, mode: .standard) }
  }
}

@MainActor private func shouldSubmit(_ key: ComposerEditorKey, modifiers: NSEvent.ModifierFlags,
  composing: Bool, text: String, shortcut: ComposerSendShortcut,
  store: WorkspaceStore) -> Bool {
  guard !composing, key == .enter else { return false }
  if modifiers.isEmpty { return shortcut.sendsOnPlainReturn(text) }
  return modifiers == .command && store.shortcuts.matches("send", ShortcutBinding("⌘↵"))
}
