import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubagentComposerView: View {
  @Binding var text: String
  let plainTextMode: Bool
  let sendShortcut: ComposerSendShortcut
  let working: Bool
  let sending: Bool
  let stopping: Bool
  let canSend: Bool
  let canStop: Bool
  let stopError: String?
  let previousPrompt: String?
  let send: () -> Void
  let stop: () -> Void
  var store: WorkspaceStore? = nil
  var detail: SubagentDetailState? = nil
  var onPreviewFile: ((FileAttachment) -> Void)? = nil
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var dropTargeted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let store, let detail {
        ImageAttachmentsView(store: store, images: detail.images, removable: true,
          onRemove: { image in detail.images.removeAll { $0.id == image.id } }).disabled(sending || detail.importing)
        FileAttachmentsView(store: store, files: detail.files, removable: true, onPreview: onPreviewFile,
          onRemove: { file in detail.files.removeAll { $0.id == file.id } }).disabled(sending || detail.importing)
      }
      ComposerTextEditor(text: $text, focused: $focused, plainTextMode: plainTextMode,
        placeholder: working ? "引导当前子任务…" : "发送消息…", accessibilityLabel: "子任务消息",
        focusRequest: focusRequest, onKey: handleKey,
        onPasteAttachments: { providers in
          guard let store, let detail else { return }
          Task { _ = await detail.importProviders(providers, root: store.dataRoot) }
        }, localCommands: localCommands)
        .frame(minHeight: 50, maxHeight: 118).accessibilityIdentifier("subagent-composer")
      if let message = stopError ?? detail?.attachmentError {
        Text(message).appFont(size: 12).foregroundStyle(.red).accessibilityIdentifier("subagent-operation-error")
      }
      HStack(spacing: 8) {
        if let store, let detail {
          Button {
            guard let window = NSApp.keyWindow else { return }
            detail.chooseAttachments(root: store.dataRoot, window: window)
          } label: { Image(systemName: "plus").frame(width: 16, height: 16) }
            .buttonStyle(.plain).disabled(sending || stopping || detail.importing)
            .accessibilityLabel("添加子任务附件").accessibilityIdentifier("subagent-attach")
          if detail.importing { ProgressView().controlSize(.small).accessibilityLabel("正在导入子任务附件") }
        }
        Spacer()
        if working {
          Button(action: stop) {
            if stopping { ProgressView().controlSize(.small) }
            else { Image(systemName: "stop.fill").frame(width: 16, height: 16) }
          }.disabled(!canStop || stopping).accessibilityLabel("停止子任务")
            .accessibilityIdentifier("subagent-stop")
        }
        Button(working ? "引导" : "发送", action: send)
          .disabled(!canSend || sending || stopping).accessibilityIdentifier("subagent-send")
      }
    }.padding(12)
      .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
      .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
        guard let store, let detail, !sending, !stopping, !detail.importing else { return false }
        Task { _ = await detail.importProviders(providers, root: store.dataRoot) }
        return true
      }
  }

  private var localCommands: ComposerCommandContext {
    var enabled: Set<String> = []
    if !text.isEmpty || detail?.hasInput == true { enabled.insert("clear-prompt") }
    if canSend && !sending && !stopping {
      enabled.insert("send")
      if working { enabled.insert("steer-prompt") }
    }
    if working && canStop && !stopping { enabled.insert("stop") }
    if store != nil, let detail, detail.selected?.acceptsInput == true,
      !sending, !stopping, !detail.importing { enabled.formUnion(["add-photos", "add-files"]) }
    return .init(enabled: enabled, perform: { command in
      switch command {
      case "send", "steer-prompt": send()
      case "stop": stop()
      case "clear-prompt": if let detail { detail.clearDraft() } else { text = "" }
      case "add-photos", "add-files":
        guard let store, let detail, let window = NSApp.keyWindow else { return }
        detail.chooseAttachments(root: store.dataRoot, window: window, imagesOnly: command == "add-photos")
      default: break
      }
    })
  }

  private func handleKey(_ key: ComposerEditorKey, _ modifiers: NSEvent.ModifierFlags, _ composing: Bool) -> Bool {
    guard !composing else { return false }
    if key == .up, modifiers.isEmpty, text.isEmpty, let previousPrompt {
      text = previousPrompt; return true
    }
    if key == .enter, modifiers == .command || modifiers.isEmpty && sendShortcut.sendsOnPlainReturn(text) {
      if canSend && !sending && !stopping { send() }
      return true
    }
    return false
  }
}
