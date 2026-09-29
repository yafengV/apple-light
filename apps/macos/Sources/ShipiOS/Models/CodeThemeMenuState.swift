import Foundation
import Observation

@MainActor @Observable final class CodeThemeMenuState: SettingsPopupMenuState {
  private(set) var presented = false
  private(set) var dark = false
  var highlightedID: String?
  private var search = ""
  private var lastTypedAt: TimeInterval?
  var options: [CodeThemePreset] { CodeThemeCatalog.options(dark: dark) }
  func open(dark: Bool, keyboard: Bool) {
    self.dark = dark; presented = true
    highlightedID = keyboard ? options.first?.id : nil
    search = ""; lastTypedAt = nil
  }
  func dismiss() { presented = false; highlightedID = nil; search = ""; lastTypedAt = nil }
  func move(_ delta: Int) {
    guard presented, !options.isEmpty else { return }
    let index = highlightedID.flatMap { id in options.firstIndex { $0.id == id } }
    highlightedID = options[index.map { max(0, min(options.count - 1, $0 + delta)) } ?? (delta < 0 ? options.count - 1 : 0)].id
  }
  func edge(last: Bool) {
    guard presented else { return }; highlightedID = last ? options.last?.id : options.first?.id
  }
  func hover(_ id: String?) {
    guard presented, id == nil || options.contains(where: { $0.id == id }) else { return }
    highlightedID = id
  }
  /// The distributed menu reads DOM textContent, including the Aa preview glyph.
  func type(_ character: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard presented else { return }
    if lastTypedAt.map({ now - $0 >= 1 }) != false { search = "" }
    search += character; lastTypedAt = now
    let chars = Array(search)
    let pattern = chars.count > 1 && chars.allSatisfy({ $0 == chars.first }) ? String(chars[0]) : search
    let start = highlightedID.flatMap { id in options.firstIndex { $0.id == id } } ?? 0
    let candidates = (0..<options.count).map { options[($0 + start) % options.count] }
    if let match = candidates.first(where: {
      !(pattern.utf16.count == 1 && $0.id == highlightedID) && ("Aa" + $0.label).lowercased().hasPrefix(pattern.lowercased())
    }), match.id != highlightedID { highlightedID = match.id }
  }
  func space(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    guard presented else { return false }
    if lastTypedAt.map({ now - $0 < 1 }) == true, !search.isEmpty { type(" ", now: now); return false }
    return true
  }
  @discardableResult func choose(_ id: String, store: WorkspaceStore) -> Bool {
    guard presented, options.contains(where: { $0.id == id }), store.libraryLoaded, !store.restoringLibrary else { return false }
    _ = store.selectCodeTheme(id, dark: dark)
    dismiss()
    return true
  }
}

extension AppearancePreferences {
  func themeSwatch(dark: Bool) -> SettingsMenuSwatch {
    let theme = themeShare(dark: dark).theme
    return .init(accent: theme.accent, foreground: theme.ink, background: theme.surface)
  }
}
extension CodeThemePreset {
  func swatch(dark: Bool) -> SettingsMenuSwatch? {
    guard let seed = variant(dark: dark)?.seed else { return nil }
    return .init(accent: seed.accent ?? "#339cff", foreground: seed.ink ?? (dark ? "#ffffff" : "#1a1c1f"),
      background: seed.surface ?? (dark ? "#181818" : "#ffffff"))
  }
}
