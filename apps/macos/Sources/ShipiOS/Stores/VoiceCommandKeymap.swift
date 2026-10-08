import Foundation

extension WorkspaceStore {
  /// Both settings pages project the same voice preferences. The app migrates
  /// legacy command settings on its first save; it never writes two files for
  /// one command-map change or reset.
  func connectShortcutSettingsStorage() {
    shortcuts.voicePreferences = { [weak self] in self?.voicePreferences ?? VoicePreferences() }
    shortcuts.voiceRegistrationError = { [weak self] in self?.voiceShortcutRegistrationErrors[$0] }
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
      guard let snapshot = restored.shortcutPreferences, snapshot.version == 1 else {
        throw AgentFailure(message: "无法读取工作区快捷键设置，已保留当前绑定。")
      }
      self.library.shortcutPreferences = snapshot
      return snapshot
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
      if !changed.isEmpty {
        if let error = shortcuts.loadError { throw AgentFailure(message: error) }
        try validateVoiceBindings(next, changed: changed)
      }
      var candidate = library
      candidate.voicePreferences = next
      if let shortcutSnapshot { candidate.shortcutPreferences = shortcutSnapshot }
      else if candidate.shortcutPreferences == nil, shortcuts.loadError == nil {
        candidate.shortcutPreferences = shortcuts.snapshot
      }
      let persist = {
        try candidate.save(to: self.dataRoot.appendingPathComponent("workspace.json"))
        self.library = candidate
      }
      if !changed.isEmpty, let commit = voiceHotkeyPreferenceCommitHandler {
        try commit(previous, next, persist)
      } else { try persist() }
      generalSettingsError = nil
      if !changed.isEmpty { globalDictationHotkeyChangeHandler?() }
    } catch let failure as VoiceHotkeyRegistrationFailure {
      voiceShortcutRegistrationErrors[failure.mode] = failure.message
      throw failure
    } catch {
      generalSettingsError = error.localizedDescription
      changed.forEach { voiceShortcutRegistrationErrors[$0] = error.localizedDescription }
      throw error
    }
  }

  private func validateVoiceBindings(_ next: VoicePreferences,
    changed: [VoiceShortcutPresentation.Mode]) throws {
    for mode in changed {
      guard let binding = next[mode] else { continue }
      var message = binding.validationMessage(for: mode.commandID)
      if message == nil, let conflict = DesktopCommand.all.first(where: {
        !$0.allowsBareModifiers && shortcuts.matches($0.id, binding)
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
