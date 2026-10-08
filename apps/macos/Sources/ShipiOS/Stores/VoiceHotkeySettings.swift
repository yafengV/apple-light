import Foundation

extension WorkspaceStore {
  /// Called after restoration with the application's real Carbon objects.
  /// Tests use this same connection, including initial registration and retry.
  func connectVoiceHotkeys(_ registration: VoiceHotkeyRegistrationController,
    didRefresh: @escaping (_ holdBindingChanged: Bool) -> Void) {
    voiceHotkeyPreferenceCommitHandler = { previous, preferences, persist in
      try registration.commit(preferences, replacing: previous, persist: persist)
    }
    let refresh: (VoiceShortcutPresentation.Mode?) -> Void = { [weak self] mode in
      guard let self else { return }
      let result = registration.refresh(self.voicePreferences, retrying: mode)
      for attempted in result.attempted {
        self.voiceShortcutRegistrationErrors[attempted] = registration.errors[attempted]
      }
      didRefresh(result.holdBindingChanged)
    }
    globalDictationHotkeyChangeHandler = { refresh(nil) }
    voiceHotkeyRegistrationRetryHandler = { refresh($0) }
    refresh(nil)
  }

  func retryVoiceHotkeyRegistration(_ mode: VoiceShortcutPresentation.Mode) {
    guard libraryLoaded else {
      generalSettingsError = "工作区尚未完成加载，请稍后再修改。"
      return
    }
    voiceShortcutRegistrationErrors[mode] = nil
    guard let retry = voiceHotkeyRegistrationRetryHandler else {
      voiceShortcutRegistrationErrors[mode] = "全局语音快捷键尚未就绪，请稍后重试。"
      return
    }
    retry(mode)
  }
}
