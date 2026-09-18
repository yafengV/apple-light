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
  var capture: Capture?
  var errors: [String: String] = [:]

  func toggleSearchMode() {
    capture = nil
    query = ""
    searchByKeys.toggle()
  }
  func begin(_ commandID: String, replacing binding: ShortcutBinding?) {
    errors[commandID] = nil
    capture = Capture(commandID: commandID, original: binding)
  }
  func cancel(_ id: UUID) {
    if capture?.id == id { capture = nil }
  }
  func receiveSearch(_ event: NSEvent) {
    guard !event.isARepeat else { return }
    if isEscape(event) { query = ""; searchByKeys = false; return }
    if let binding = ShortcutBinding(event: event) { query = binding.display }
  }
  func receive(_ event: NSEvent, sessionID: UUID, preferences: ShortcutPreferences) {
    guard let session = capture, session.id == sessionID, !event.isARepeat else { return }
    if isEscape(event) { cancel(sessionID); return }
    guard let binding = ShortcutBinding(event: event) else { return }
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
  func clearSearch() { query = ""; searchByKeys = false; capture = nil }
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
