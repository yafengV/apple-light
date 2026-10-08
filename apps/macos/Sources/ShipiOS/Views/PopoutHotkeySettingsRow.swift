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
      HStack(spacing: 8) {
        if capturing {
          ShortcutCapture(text: "按下快捷键", accessibilityLabel: "捕获弹出窗口快捷键",
            receive: { receive($0, sessionID: sessionID) }, activityChanged: { active in
              store.shortcutCaptureCount = max(0, store.shortcutCaptureCount + (active ? 1 : -1))
            }, onBlur: { capturing = false }, receiveRegistered: { binding in
              receive(binding, sessionID: sessionID)
            })
            .frame(width: 144, height: 28)
        } else {
          Button(store.shortcuts.binding("popout")?.display ?? "关闭") {
            error = nil
            captureID = UUID()
            capturing = true
          }.accessibilityLabel("弹出窗口快捷键")
        }
        if store.shortcuts.binding("popout") != nil {
          Button {
            capturing = false
            do { try store.shortcuts.set(nil, for: "popout"); error = nil }
            catch { self.error = error.localizedDescription }
          } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .accessibilityLabel("清除弹出窗口快捷键")
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
    if let message = binding.validationMessage(for: "popout") {
      error = message
      return
    }
    if let conflict = store.shortcuts.conflict(for: binding, excluding: "popout") {
      error = "已用于“\(conflict.title)”"
      return
    }
    do {
      try store.shortcuts.set(binding, for: "popout")
      error = nil
      capturing = false
    } catch { self.error = error.localizedDescription }
  }
}
