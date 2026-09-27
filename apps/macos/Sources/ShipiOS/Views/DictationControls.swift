import SwiftUI

struct DictationButton: View {
  @Bindable var store: WorkspaceStore
  let target: String
  var enabled = true

  private var active: Bool { store.dictation.target == target }

  var body: some View {
    Button {
      Task { await store.toggleDictation(target: target) }
    } label: {
      Image(systemName: active ? "waveform" : "mic")
        .frame(width: 26, height: 26)
        .foregroundStyle(active ? Color.red : Color.primary)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .help((active ? "结束听写" : "开始听写") + " " + store.shortcuts.label("dictation"))
    .accessibilityLabel(active ? "结束听写" : "开始听写")
  }
}

struct DictationStatusView: View {
  @Bindable var store: WorkspaceStore
  let target: String

  var body: some View {
    if store.dictation.target == target {
      HStack(spacing: 8) {
        Image(systemName: "waveform").foregroundStyle(.red)
        Text(store.dictation.phase == .requestingAccess ? "正在等待麦克风和语音识别权限…"
          : store.dictation.partial.isEmpty ? "正在听写…" : store.dictation.partial)
          .lineLimit(2)
        Spacer()
        Button("完成") { store.dictation.stop(target: target) }
      }.appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
    } else if store.dictation.errorTarget == target, let error = store.dictation.error {
      HStack(spacing: 8) {
        Text(error).foregroundStyle(.orange).textSelection(.enabled)
        Spacer()
        Button("关闭") { store.dictation.clearError(for: target) }
      }.appFont(.caption).padding(.horizontal, 4)
    }
  }
}
