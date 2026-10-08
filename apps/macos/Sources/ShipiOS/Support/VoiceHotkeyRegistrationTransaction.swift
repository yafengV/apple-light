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
    let changes = changes(preferences, replacing: previous)
    let prepared: AppGlobalHotKey.PreparedRegistration
    do { prepared = try AppGlobalHotKey.prepareRegistrations(changes.map { ($0.key, $0.binding) }) }
    catch let failure as AppGlobalHotKey.PreparationFailure {
      throw VoiceHotkeyRegistrationFailure(mode: changes[failure.index].mode, message: failure.localizedDescription)
    }
    try persist()
    prepared.commit()
  }

  func changes(_ preferences: VoicePreferences, replacing previous: VoicePreferences)
    -> [(mode: VoiceShortcutPresentation.Mode, key: AppGlobalHotKey, binding: ShortcutBinding?)] {
    [
      (VoiceShortcutPresentation.Mode.hold, hold, preferences.globalHoldHotkey, previous.globalHoldHotkey),
      (.toggle, toggle, preferences.globalToggleHotkey, previous.globalToggleHotkey),
      (.voiceChat, voiceChat, preferences.globalVoiceChatHotkey, previous.globalVoiceChatHotkey),
    ].compactMap { mode, key, binding, oldBinding in
      guard binding != oldBinding else { return nil }
      return (mode, key, binding?.isBareModifier == true ? nil : binding)
    }
  }
}
