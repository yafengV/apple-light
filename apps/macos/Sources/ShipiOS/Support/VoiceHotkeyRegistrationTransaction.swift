import Foundation

struct VoiceHotkeyRegistrationFailure: LocalizedError {
  let mode: VoiceShortcutPresentation.Mode
  let message: String
  var errorDescription: String? { message }
}

/// Changed native registrations and workspace save share one synchronous
/// MainActor operation. Neither an OS conflict nor a failed save removes the
/// previous registrations. Bare-modifier monitoring is refreshed after commit.
@MainActor struct VoiceHotkeyRegistrationTransaction {
  let hold: AppGlobalHotKey
  let toggle: AppGlobalHotKey
  let voiceChat: AppGlobalHotKey

  func commit(_ preferences: VoicePreferences, replacing previous: VoicePreferences,
    persist: () throws -> Void) throws {
    var prepared: [AppGlobalHotKey.PreparedRegistration] = []
    for (mode, key, binding, oldBinding) in [
      (VoiceShortcutPresentation.Mode.hold, hold, preferences.globalHoldHotkey, previous.globalHoldHotkey),
      (.toggle, toggle, preferences.globalToggleHotkey, previous.globalToggleHotkey),
      (.voiceChat, voiceChat, preferences.globalVoiceChatHotkey, previous.globalVoiceChatHotkey),
    ] where binding != oldBinding {
      do { prepared.append(try key.prepareRegistration(binding?.isBareModifier == true ? nil : binding)) }
      catch { throw VoiceHotkeyRegistrationFailure(mode: mode, message: error.localizedDescription) }
    }
    try persist()
    prepared.forEach { $0.commit() }
  }
}
