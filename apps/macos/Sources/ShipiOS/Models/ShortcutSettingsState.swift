import AppKit
import Observation

@MainActor @Observable final class ShortcutSettingsState {
  struct Capture: Identifiable, Equatable {
    let id = UUID()
    let commandID: String
    let original: ShortcutBinding?
    var warning: String?
  }
  var query = ""
  var searchByKeys = false
  private(set) var searchCaptureID = UUID()
  var capture: Capture?
  var errors: [String: String] = [:]
  var dictationAdvancedExpanded = false
  private var modifierCapture = VoiceModifierCaptureState()

  func dictationGroup(preferences: ShortcutPreferences) -> ShortcutDictationGroup {
    ShortcutDictationGroup(commandIDs: DesktopCommand.all.filter { matches($0, preferences: preferences) }.map(\.id),
      query: query, searchByKeys: searchByKeys, expanded: dictationAdvancedExpanded)
  }
  func setDictationExpanded(_ expanded: Bool) {
    if !expanded, let capture, capture.commandID == ShortcutDictationGroup.toggleID { cancel(capture.id) }
    dictationAdvancedExpanded = expanded
  }
  func searchChanged(preferences: ShortcutPreferences) {
    capture = nil; modifierCapture.reset()
    if !dictationGroup(preferences: preferences).showsCard { dictationGroupRemoved() }
  }
  func dictationGroupRemoved() {
    dictationAdvancedExpanded = false
    if let capture, [ShortcutDictationGroup.holdID, ShortcutDictationGroup.toggleID].contains(capture.commandID) {
      cancel(capture.id)
    }
  }
  func leavePage() {
    capture = nil; modifierCapture.reset(); dictationAdvancedExpanded = false
    searchByKeys = false; searchCaptureID = UUID()
  }
  func matchesNumberPreference(_ target: NumberShortcutTarget) -> Bool {
    guard !searchByKeys else { return false }
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || ["数字快捷键", "Number shortcuts", "⌘1–9 切换聊天", "⌘1–9 切换标签",
      target == .tabs ? "使用 ⌘1–9 切换标签，⌃1–9 切换聊天" : "使用 ⌘1–9 切换聊天，⌃1–9 切换标签"]
      .contains { $0.localizedCaseInsensitiveContains(value) }
  }

  func toggleSearchMode() {
    capture = nil
    query = ""
    searchByKeys.toggle()
    searchCaptureID = UUID()
  }
  func begin(_ commandID: String, replacing binding: ShortcutBinding?) {
    errors[commandID] = nil
    modifierCapture.reset()
    capture = Capture(commandID: commandID, original: binding)
  }
  func cancel(_ id: UUID) {
    if capture?.id == id { capture = nil; modifierCapture.reset() }
  }
  func receiveSearch(_ event: NSEvent) {
    guard !event.isARepeat else { return }
    if isEscape(event) { query = ""; searchByKeys = false; return }
    if let binding = ShortcutBinding(event: event) { receiveSearch(binding, sessionID: searchCaptureID) }
  }
  func receiveSearch(_ binding: ShortcutBinding, sessionID: UUID) {
    guard searchByKeys, searchCaptureID == sessionID else { return }
    query = binding.display
  }
  func receive(_ event: NSEvent, sessionID: UUID, preferences: ShortcutPreferences) {
    guard let session = capture, session.id == sessionID, !event.isARepeat else { return }
    modifierCapture.reset()
    if isEscape(event) { cancel(sessionID); return }
    guard let binding = ShortcutBinding(event: event) else { return }
    receive(binding, sessionID: sessionID, preferences: preferences)
  }
  func receiveModifier(_ event: NSEvent, sessionID: UUID, preferences: ShortcutPreferences) {
    guard let session = capture, session.id == sessionID,
      DesktopCommand.all.first(where: { $0.id == session.commandID })?.allowsBareModifiers == true,
      let binding = modifierCapture.flagsChanged(event.modifierFlags) else { return }
    receive(binding, sessionID: sessionID, preferences: preferences)
  }
  func receive(_ binding: ShortcutBinding, sessionID: UUID, preferences: ShortcutPreferences) {
    guard let session = capture, session.id == sessionID else { return }
    // Carbon combinations do not pass through receive(keyDown:). Their later
    // modifier release must not become a second, bare-modifier candidate.
    modifierCapture.reset()
    if binding == session.original { cancel(sessionID); return }
    if let conflict = preferences.conflict(for: binding, excluding: session.commandID) {
      capture?.warning = "已用于“\(conflict.title)”"
      return
    }
    if let validation = binding.validationMessage(for: session.commandID),
      !(session.commandID == "pet" && binding.option && !binding.command && !binding.control) {
      capture?.warning = validation
      return
    }
    change(session.commandID) { try preferences.replace(session.original, with: binding, for: session.commandID) }
  }
  func change(_ commandID: String, action: () throws -> Void) {
    capture = nil
    errors[commandID] = nil
    do { try action() } catch { errors[commandID] = error.localizedDescription }
  }
  func clearSearch() { query = ""; searchByKeys = false; searchCaptureID = UUID(); capture = nil }
  func matchesExternalBrowserShortcut(_ shortcut: ExternalBrowserLinkShortcut) -> Bool {
    guard !searchByKeys else { return false }
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || ["在默认浏览器中打开网页链接",
      "按住所选按键并点按网页链接，即可在系统默认浏览器中打开", shortcut.title,
      "Open web link in default browser"].contains { $0.localizedCaseInsensitiveContains(value) }
  }
  func matches(_ command: DesktopCommand, preferences: ShortcutPreferences) -> Bool {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return true }
    if searchByKeys { return preferences.bindings(command.id).contains { $0.display == value } }
    return command.title.localizedCaseInsensitiveContains(value) || command.id.localizedCaseInsensitiveContains(value)
  }
  private func isEscape(_ event: NSEvent) -> Bool {
    event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
  }
}
