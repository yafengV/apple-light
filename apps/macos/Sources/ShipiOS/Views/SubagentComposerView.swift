import AppKit
import SwiftUI

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
  @State private var focused = false
  @State private var focusRequest = UUID()
  @State private var attachmentError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ComposerTextEditor(text: $text, focused: $focused, plainTextMode: plainTextMode,
        placeholder: working ? "引导当前子任务…" : "发送消息…", accessibilityLabel: "子任务消息",
        focusRequest: focusRequest, onKey: handleKey,
        onPasteAttachments: { _ in attachmentError = "子任务目前只接受文字，请在父任务中添加附件。" }, localCommands: localCommands)
        .frame(minHeight: 50, maxHeight: 118).accessibilityIdentifier("subagent-composer")
      if let message = stopError ?? attachmentError {
        Text(message).appFont(size: 12).foregroundStyle(.red).accessibilityIdentifier("subagent-operation-error")
      }
      HStack(spacing: 8) {
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
  }

  private var localCommands: ComposerCommandContext {
    var enabled: Set<String> = []
    if !text.isEmpty { enabled.insert("clear-prompt") }
    if canSend && !sending && !stopping {
      enabled.insert("send")
      if working { enabled.insert("steer-prompt") }
    }
    if working && canStop && !stopping { enabled.insert("stop") }
    return .init(enabled: enabled, perform: { command in
      switch command {
      case "send", "steer-prompt": send()
      case "stop": stop()
      case "clear-prompt": text = ""
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
