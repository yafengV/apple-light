import AppKit

/// The native first responder owns these commands while editing a child draft.
/// An owned but unavailable command never falls through to its parent task.
@MainActor struct ComposerCommandContext {
  var enabled: Set<String>
  let perform: (String) -> Void
  static let owned: Set<String> = ["send", "stop", "clear-prompt", "steer-prompt", "queue-prompt",
    "add-photos", "add-files", "capture-appshot", "dictation", "plan", "model",
    "reasoning-increase", "reasoning-decrease", "reasoning-cycle", "toggle-worktree-mode"]

  func execute(_ id: String) -> Bool {
    guard Self.owned.contains(id), enabled.contains(id) else { return false }
    perform(id); return true
  }
  static func focused(in window: NSWindow?) -> Self? {
    guard let editor = window?.firstResponder as? ComposerNativeTextView,
      editor.isEditable, let coordinator = editor.coordinator, coordinator.active,
      var context = coordinator.parent.localCommands else { return nil }
    if editor.hasMarkedText() { context.enabled.subtract(["send", "steer-prompt", "queue-prompt"]) }
    return context
  }
  /// Returns false for unrelated bindings; consumes owned disabled bindings too.
  static func route(_ binding: ShortcutBinding, shortcuts: ShortcutPreferences, in window: NSWindow?) -> Bool {
    guard let context = focused(in: window),
      let id = DesktopCommand.all.first(where: { owned.contains($0.id) && shortcuts.matches($0.id, binding) })?.id else { return false }
    _ = context.execute(id); return true
  }
}
