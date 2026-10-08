import Foundation

/// Owns the registrations for one application lifetime. Restored preferences
/// may be unavailable without affecting another mode's successful registration.
@MainActor final class VoiceHotkeyRegistrationController {
  typealias Mode = VoiceShortcutPresentation.Mode
  struct Refresh {
    var attempted: Set<Mode> = []
    var holdBindingChanged = false
  }
  private let transaction: VoiceHotkeyRegistrationTransaction
  private var registered: [Mode: ShortcutBinding] = [:]
  private(set) var errors: [Mode: String] = [:]

  init(hold: AppGlobalHotKey, toggle: AppGlobalHotKey, voiceChat: AppGlobalHotKey) {
    transaction = VoiceHotkeyRegistrationTransaction(hold: hold, toggle: toggle, voiceChat: voiceChat)
  }

  func commit(_ preferences: VoicePreferences, replacing previous: VoicePreferences,
    persist: () throws -> Void) throws {
    try transaction.commit(preferences, replacing: previous, persist: persist)
  }

  func refresh(_ preferences: VoicePreferences, retrying retry: Mode? = nil) -> Refresh {
    var result = Refresh()
    for (mode, key, binding) in [
      (Mode.hold, transaction.hold, preferences.globalHoldHotkey),
      (.toggle, transaction.toggle, preferences.globalToggleHotkey),
      (.voiceChat, transaction.voiceChat, preferences.globalVoiceChatHotkey),
    ] {
      guard retry.map({ $0 == mode }) ?? (registered[mode] != binding) else { continue }
      result.attempted.insert(mode)
      do {
        try key.register(binding?.isBareModifier == true ? nil : binding)
        if mode == .hold, registered[mode] != binding { result.holdBindingChanged = true }
        registered[mode] = binding
        errors[mode] = nil
      } catch { errors[mode] = error.localizedDescription }
    }
    return result
  }
}
