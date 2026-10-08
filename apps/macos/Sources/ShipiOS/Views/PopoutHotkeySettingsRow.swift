import AppKit
import SwiftUI

struct PopoutHotkeySettingsRow: View {
  @Bindable var store: WorkspaceStore
  @State private var capturing = false
  @State private var captureID = UUID()
  @State private var error: String?

  var body: some View {
    let sessionID = captureID
    LabeledContent {
      if capturing {
        HStack(spacing: 8) {
          ShortcutCapture(text: "按下快捷键", accessibilityLabel: "捕获弹出窗口快捷键",
            receive: { receive($0, sessionID: sessionID) }, activityChanged: { active in
              store.shortcutCaptureCount = max(0, store.shortcutCaptureCount + (active ? 1 : -1))
            }, onBlur: { cancel(sessionID) }, receiveRegistered: { binding in
              receive(binding, sessionID: sessionID)
            })
            .frame(width: 144, height: 28).id(sessionID)
          VoiceShortcutActionButton(kind: .cancel, label: "取消录制弹出窗口快捷键",
            identifier: "popout-hotkey-cancel") { cancel(sessionID) }
            .fixedSize().settingsFocusReveal()
        }
      } else {
        HStack(spacing: 4) {
          Text(store.shortcuts.binding("popout")?.display ?? "关闭").appFont(size: 13).lineLimit(1)
          VoiceShortcutActionButton(kind: .edit,
            label: store.shortcuts.binding("popout") == nil ? "设置弹出窗口快捷键" : "更改弹出窗口快捷键",
            identifier: "popout-hotkey-edit") {
              error = nil
              store.popoutHotkeyError = nil
              captureID = UUID()
              capturing = true
            }.fixedSize().settingsFocusReveal()
          if store.shortcuts.binding("popout") != nil {
            VoiceShortcutActionButton(kind: .clear, label: "清除弹出窗口快捷键",
              identifier: "popout-hotkey-clear") {
                do { try store.shortcuts.set(nil, for: "popout"); error = nil }
                catch { self.error = error.localizedDescription }
              }.fixedSize().settingsFocusReveal()
          }
        }
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text("弹出窗口快捷键")
        Text("为弹出窗口设置全局快捷键。不设置则保持关闭。")
          .appFont(.caption).foregroundStyle(.secondary)
        if let message = error ?? store.popoutHotkeyError {
          Text(message).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }
    }
    .onDisappear { capturing = false }
  }

  private func cancel(_ sessionID: UUID) {
    guard capturing, captureID == sessionID else { return }
    capturing = false
  }

  private func receive(_ event: NSEvent, sessionID: UUID) {
    guard capturing, captureID == sessionID, !event.isARepeat else { return }
    if event.keyCode == 53,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      capturing = false
      return
    }
    guard let binding = ShortcutBinding(event: event) else { return }
    receive(binding, sessionID: sessionID)
  }
  private func receive(_ binding: ShortcutBinding, sessionID: UUID) {
    guard capturing, captureID == sessionID else { return }
    capturing = false
    error = nil
    if let message = binding.validationMessage(for: "popout") {
      error = message
      return
    }
    if let conflict = store.shortcuts.conflict(for: binding, excluding: "popout") {
      error = "已用于“\(conflict.title)”"
      return
    }
    do {
      if binding == store.shortcuts.binding("popout") {
        try store.shortcuts.retryGlobalRegistration?("popout")
      } else { try store.shortcuts.set(binding, for: "popout") }
      error = nil
      capturing = false
    } catch { self.error = error.localizedDescription }
  }
}
