import AppKit

@MainActor enum GitHubPRMentionKeyboard {
  static func handle(_ event: NSEvent, state: GitHubPRMentionState) -> Bool {
    guard state.visible else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    if [36, 76].contains(event.keyCode), !modifiers.intersection([.command, .control]).isEmpty {
      state.dismiss(); return false
    }
    if event.keyCode == 53 { state.dismiss(); return true }
    if event.keyCode == 125 || modifiers == .control && event.charactersIgnoringModifiers == "n" {
      state.move(1); return true
    }
    if event.keyCode == 126 || modifiers == .control && event.charactersIgnoringModifiers == "p" {
      state.move(-1); return true
    }
    if modifiers.isEmpty, [36, 76, 48].contains(event.keyCode) { return state.choose() }
    return false
  }
}
