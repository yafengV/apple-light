import Foundation

extension WorkspaceStore {
  var systemInstructions: String {
    [personalization.systemInstructions(custom: customInstructions), memoryPreferences.instructions]
      .filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  func loadPersonalization() async {
    guard !personalizationLoading else { return }
    personalizationLoading = true
    defer { personalizationLoading = false }
    let root = dataRoot
    let legacy = modelConfiguration.instructions
    let unsaved = personalizationDraft != customInstructions ? personalizationDraft : nil
    personalizationLoaded = false
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        try PersonalizationStorage.load(root: root, legacyInstructions: legacy)
      }.value
      personalization = loaded.0
      customInstructions = loaded.1
      personalizationDraft = unsaved ?? loaded.1
      personalizationLoaded = true
      personalizationError = nil
    } catch { personalizationError = error.localizedDescription }
  }

  @discardableResult func savePersonality(_ personality: ResponsePersonality) -> Bool {
    guard personalizationLoaded else { return false }
    do {
      var updated = personalization
      updated.personality = personality
      try PersonalizationStorage.save(updated, root: dataRoot)
      personalization = updated
      personalizationError = nil
      return true
    } catch { personalizationError = error.localizedDescription; return false }
  }

  @discardableResult func saveSuggestedPrompts(_ visible: Bool) -> Bool {
    guard personalizationLoaded else { return false }
    do {
      var updated = personalization
      updated.showSuggestedPrompts = visible
      try PersonalizationStorage.save(updated, root: dataRoot)
      personalization = updated
      personalizationError = nil
      return true
    } catch { personalizationError = error.localizedDescription; return false }
  }

  @discardableResult func saveCustomInstructions() -> Bool {
    guard personalizationLoaded else { return false }
    do {
      try PersonalizationStorage.saveInstructions(personalizationDraft, root: dataRoot)
      customInstructions = personalizationDraft
      personalizationError = nil
      return true
    } catch { personalizationError = error.localizedDescription; return false }
  }
}
