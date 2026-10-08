import Foundation

extension WorkspaceStore {
  /// Both settings pages project the same voice preferences. The app migrates
  /// legacy command settings on its first save; it never writes two files for
  /// one command-map change or reset.
  func connectShortcutSettingsStorage() {
    shortcuts.voicePreferences = { [weak self] in self?.voicePreferences ?? VoicePreferences() }
    shortcuts.voiceRegistrationError = { [weak self] in self?.voiceShortcutRegistrationErrors[$0] }
    shortcuts.coordinatesGlobalSnapshot = { [weak self] in
      guard let self else { return false }
      return self.libraryLoaded && self.voiceRegistrationController != nil
        && self.shortcuts.globalRegistrationController != nil
    }
    shortcuts.setVoiceBinding = { [weak self] mode, binding in
      guard let self else { throw AgentFailure(message: "工作区已关闭。") }
      var next = self.voicePreferences
      next[mode] = binding
      try self.saveVoicePreferences(next)
    }
    shortcuts.persistSnapshot = { [weak self] snapshot, resetVoice, saveLegacy in
      guard let self else { throw AgentFailure(message: "工作区已关闭。") }
      // Standalone command settings remain usable before workspace restoration.
      guard self.libraryLoaded else { try saveLegacy(); return }
      var next = self.voicePreferences
      if resetVoice { VoiceShortcutPresentation.Mode.allCases.forEach { next[$0] = nil } }
      try self.saveVoicePreferences(next, shortcutSnapshot: snapshot)
    }
    shortcuts.readSnapshot = { [weak self] in
      guard let self, self.libraryLoaded, self.library.shortcutPreferences != nil else { return nil }
      let restored: WorkspaceLibrary
      do {
        restored = try JSONDecoder().decode(WorkspaceLibrary.self,
          from: Data(contentsOf: self.dataRoot.appendingPathComponent("workspace.json")))
      } catch {
        // Once migrated, a missing canonical file is a read failure, not a
        // request to silently fall back to stale legacy defaults.
        throw AgentFailure(message: "无法读取工作区快捷键设置：\(error.localizedDescription)")
      }
      guard let snapshot = restored.shortcutPreferences else {
        throw AgentFailure(message: "无法读取工作区快捷键设置，已保留当前绑定。")
      }
      let upgraded = try snapshot.upgradingCommandBindings()
      self.library.shortcutPreferences = upgraded
      return upgraded
    }
  }

  func saveVoicePreferences(_ next: VoicePreferences,
    shortcutSnapshot: ShortcutPreferencesSnapshot? = nil) throws {
    let previous = voicePreferences
    guard previous != next || shortcutSnapshot != nil else { return }
    guard libraryLoaded else {
      let failure = AgentFailure(message: "工作区尚未完成加载，请稍后再修改。")
      generalSettingsError = failure.message
      throw failure
    }
    let changed = VoiceShortcutPresentation.Mode.allCases.filter { previous[$0] != next[$0] }
    changed.forEach { voiceShortcutRegistrationErrors[$0] = nil }
    do {
      let shortcutSnapshot = try shortcutSnapshot?.upgradingCommandBindings()
      if !changed.isEmpty {
        if let error = shortcuts.loadError { throw AgentFailure(message: error) }
        try validateVoiceBindings(next, changed: changed, shortcutSnapshot: shortcutSnapshot)
      }
      var candidate = library
      candidate.voicePreferences = next
      if let shortcutSnapshot { candidate.shortcutPreferences = shortcutSnapshot }
      else if shortcuts.loadError == nil {
        candidate.shortcutPreferences = shortcuts.snapshot
      }
      let persist = {
        try candidate.save(to: self.dataRoot.appendingPathComponent("workspace.json"))
        self.library = candidate
      }
      if let shortcutSnapshot, let commands = shortcuts.globalRegistrationController,
        let voice = voiceRegistrationController {
        let oldCommands = CommandGlobalHotkeyBindings(pet: shortcuts.binding("pet"), popout: shortcuts.binding("popout"))
        let newCommands = shortcuts.globalBindings(in: shortcutSnapshot)
        try GlobalHotkeyRegistrationBatch.commit(commands: commands, previousCommands: oldCommands,
          nextCommands: newCommands, voice: voice, previousVoice: previous, nextVoice: next, persist: persist)
        for id in CommandGlobalHotkeyBindings.commandIDs where oldCommands[id] != newCommands[id] {
          shortcuts.globalRegistrationErrors[id] = nil
        }
      } else if !changed.isEmpty, let commit = voiceHotkeyPreferenceCommitHandler {
        try commit(previous, next, persist)
      } else { try persist() }
      if let shortcutSnapshot { shortcuts.publish(shortcutSnapshot) }
      generalSettingsError = nil
      if !changed.isEmpty { globalDictationHotkeyChangeHandler?() }
    } catch let failure as VoiceHotkeyRegistrationFailure {
      voiceShortcutRegistrationErrors[failure.mode] = failure.message
      throw failure
    } catch let failure as CommandGlobalHotkeyFailure {
      shortcuts.globalRegistrationErrors[failure.commandID] = failure.message
      throw failure
    } catch {
      generalSettingsError = error.localizedDescription
      changed.forEach { voiceShortcutRegistrationErrors[$0] = error.localizedDescription }
      throw error
    }
  }

  private func validateVoiceBindings(_ next: VoicePreferences,
    changed: [VoiceShortcutPresentation.Mode], shortcutSnapshot: ShortcutPreferencesSnapshot?) throws {
    for mode in changed {
      guard let binding = next[mode] else { continue }
      var message = binding.validationMessage(for: mode.commandID)
      if message == nil, let conflict = DesktopCommand.all.first(where: { command in
        !command.allowsBareModifiers && (shortcutSnapshot.map { snapshot in
          shortcuts.bindings(command.id, in: snapshot).contains(binding)
        } ?? shortcuts.matches(command.id, binding))
      }) { message = "已用于“\(conflict.title)”，请先移除该绑定。" }
      if message == nil {
        for other in VoiceShortcutPresentation.Mode.allCases where other != mode {
          guard let existing = next[other] else { continue }
          if existing == binding {
            message = mode != .voiceChat && other != .voiceChat
              ? "请为单击听写选择不同的快捷键。"
              : "已用于“\(other.title)”，请先移除该绑定。"
            break
          }
          if binding.isBareModifier, existing.isBareModifier,
            binding.modifierFlags.isSubset(of: existing.modifierFlags)
              || existing.modifierFlags.isSubset(of: binding.modifierFlags) {
            message = "与“\(other.title)”的修饰键组合重叠，请选择不同组合。"
            break
          }
        }
      }
      if let message { throw VoiceHotkeyRegistrationFailure(mode: mode, message: message) }
    }
  }
}
