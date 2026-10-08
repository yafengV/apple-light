import Foundation

/// One native plan for the five shared command-map bindings. Transfer existing
/// registrations across controllers; publish no ownership changes before save.
@MainActor enum GlobalHotkeyRegistrationBatch {
  static func commit(commands: CommandGlobalHotkeyRegistration,
    previousCommands: CommandGlobalHotkeyBindings, nextCommands: CommandGlobalHotkeyBindings,
    voice: VoiceHotkeyRegistrationController, previousVoice: VoicePreferences, nextVoice: VoicePreferences,
    persist: () throws -> Void) throws {
    let commandChanges = commands.changes(nextCommands, replacing: previousCommands)
    let voiceChanges = voice.changes(nextVoice, replacing: previousVoice)
    let requests = commandChanges.map { ($0.key, $0.binding) } + voiceChanges.map { ($0.key, $0.binding) }
    let prepared: AppGlobalHotKey.PreparedRegistration
    do { prepared = try AppGlobalHotKey.prepareRegistrations(requests) }
    catch let failure as AppGlobalHotKey.PreparationFailure {
      if failure.index < commandChanges.count {
        let id = commandChanges[failure.index].id
        commands.noteFailure(id, message: failure.localizedDescription)
        throw CommandGlobalHotkeyFailure(commandID: id, message: failure.localizedDescription)
      }
      throw VoiceHotkeyRegistrationFailure(mode: voiceChanges[failure.index - commandChanges.count].mode,
        message: failure.localizedDescription)
    }
    try persist()
    prepared.commit()
    commands.accept(nextCommands, replacing: previousCommands)
  }
}
