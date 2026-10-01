import Foundation

extension WorkspaceStore {
  func toggleDictation(target: String) async {
    guard !shuttingDown else { return }
    if dictation.target == target {
      dictation.stop(target: target)
      return
    }
    let initial = library.drafts[target] ?? ""
    let selection = dictationCarets[target].flatMap { $0.text == initial ? $0.range : nil }
    await dictation.start(target: target,
      languageIdentifier: voicePreferences.dictationLocaleIdentifier,
      microphoneDeviceID: voicePreferences.microphoneDeviceID,
      dictionary: voicePreferences.dictationDictionary) { [weak self] key, transcript in
      guard let self, !self.shuttingDown,
        key.hasPrefix("new:") || self.library.tasks.contains(where: { $0.id == key }) else { return }
      let current = self.library.drafts[key] ?? ""
      let updated = DictationDraftInsertion.apply(transcript, to: current,
        initial: initial, selection: selection)
      guard updated != current else { return }
      self.library.drafts[key] = updated
      self.saveLibrary()
    }
  }
}
