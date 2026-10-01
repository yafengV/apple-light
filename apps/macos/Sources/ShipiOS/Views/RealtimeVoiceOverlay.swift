import SwiftUI

struct RealtimeVoiceOverlay: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    ZStack {
      Color.black.opacity(0.48).ignoresSafeArea()
      VStack(spacing: 20) {
        HStack {
          Text("语音聊天").appFont(size: 18, weight: .semibold)
          Spacer()
          Button { store.dismissVoiceChat() } label: {
            Image(systemName: "xmark").frame(width: 26, height: 26)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("结束语音聊天")
        }
        Spacer(minLength: 0)
        Image(systemName: statusSymbol)
          .font(.system(size: 52, weight: .light))
          .foregroundStyle(store.realtimeVoice.phase == .failed ? .red : .primary)
          .frame(height: 74)
          .accessibilityHidden(true)
        Text(statusText).appFont(size: 16, weight: .medium)
          .accessibilityIdentifier("voice-chat-status")
        if !store.realtimeVoice.userText.isEmpty {
          Text(store.realtimeVoice.userText).appFont(size: 13)
            .foregroundStyle(.secondary).lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("你的语音：\(store.realtimeVoice.userText)")
        }
        if !store.realtimeVoice.assistantText.isEmpty {
          Text(store.realtimeVoice.assistantText).appFont(size: 14)
            .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("助手：\(store.realtimeVoice.assistantText)")
        }
        if let error = store.realtimeVoice.error {
          Text(error).appFont(.caption).foregroundStyle(.red)
            .multilineTextAlignment(.center).textSelection(.enabled)
        }
        if let screenStatus = store.realtimeVoice.screenContextStatus {
          Text(screenStatus).appFont(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).textSelection(.enabled)
        }
        Spacer(minLength: 0)
        HStack(spacing: 14) {
          if store.realtimeVoice.phase == .failed {
            Button("重试") { store.presentVoiceChat() }
            Button("语音设置") {
              store.dismissVoiceChat()
              store.openSettings(.voice)
            }
          } else {
            Button {
              store.realtimeVoice.toggleMute()
            } label: {
              Label(store.realtimeVoice.muted ? "取消静音" : "静音",
                systemImage: store.realtimeVoice.muted ? "mic.slash.fill" : "mic.fill")
            }
            .disabled(store.realtimeVoice.phase == .connecting)
          }
          Button("结束") { store.dismissVoiceChat() }
            .keyboardShortcut(.escape, modifiers: [])
        }
      }
      .padding(24)
      .frame(width: 440).frame(minHeight: 360)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
      .shadow(radius: 28)
    }
    .accessibilityIdentifier("realtime-voice-overlay")
    .onExitCommand { store.dismissVoiceChat() }
  }

  private var statusText: String {
    switch store.realtimeVoice.phase {
    case .idle: "语音聊天已结束"
    case .connecting: "正在连接语音服务…"
    case .listening: store.realtimeVoice.muted ? "麦克风已静音" : "正在聆听"
    case .thinking: "正在思考…"
    case .speaking: "正在回复"
    case .failed: "语音聊天无法开始"
    }
  }

  private var statusSymbol: String {
    switch store.realtimeVoice.phase {
    case .idle, .connecting: "waveform.circle"
    case .listening: store.realtimeVoice.muted ? "mic.slash.circle" : "waveform"
    case .thinking: "ellipsis.circle"
    case .speaking: "waveform.circle.fill"
    case .failed: "exclamationmark.circle"
    }
  }
}
