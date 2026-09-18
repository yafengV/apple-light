import Foundation

extension WorkspaceStore {
  func requestShortcutReset() {
    guard !hasSettingsConfirmation, presentedOverlay == nil, shortcuts.hasCustomizations else { return }
    shortcutResetError = nil
    shortcutResetRequested = true
  }
  func dismissShortcutReset() {
    guard !resettingShortcuts else { return }
    shortcutResetRequested = false
    shortcutResetError = nil
  }
  func confirmShortcutReset() async {
    guard shortcutResetRequested, !resettingShortcuts else { return }
    resettingShortcuts = true
    defer { resettingShortcuts = false }
    await Task.yield()
    do {
      try shortcuts.resetAll()
      shortcutResetRequested = false
      shortcutResetError = nil
    } catch { shortcutResetError = error.localizedDescription }
  }
}
