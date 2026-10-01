import Foundation

extension WorkspaceStore {
  func presentVoiceChat() {
    guard !shuttingDown else { return }
    if let target = dictation.target { dictation.finish(target: target) }
    voiceChatPresented = true
    showMainWindowHandler?()
    if !realtimeVoice.isActive {
      Task { await realtimeVoice.start(config: modelConfiguration,
        preferences: voicePreferences, screenCapture: appshotCapture) }
    }
  }

  func dismissVoiceChat() {
    voiceChatPresented = false
    realtimeVoice.stop()
  }
}
