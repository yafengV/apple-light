import Foundation
import Observation

struct ThemeCommandItem: Identifiable {
  enum Action: Equatable { case back, switchMode, preset(String) }
  let id: String
  let title: String
  let description: String?
  let icon: String?
  let action: Action
  let selected: Bool
  let swatch: SettingsMenuSwatch?
  let searchText: String
}

/// A drill-in stays in the invoking window; only the appearance preference is shared.
@MainActor @Observable final class ThemeCommandMenu {
  private(set) var entered = false
  var selectedID: String?
  func enter() { entered = true; selectedID = nil }
  func back() { entered = false; selectedID = nil }

  static func rootDescription(_ appearance: AppearancePreferences) -> String {
    let dark = appearance.isDark
    return CodeThemeCatalog.preset(dark ? appearance.codeThemes.dark : appearance.codeThemes.light, dark: dark)?.label ?? "Codex"
  }
  static func rootMatches(_ query: String, appearance: AppearancePreferences) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
      DesktopFuzzyQuery(query).match("主题 theme appearance \(rootDescription(appearance)) color theme preset dark light night 颜色 外观 预设 浅色 深色") != nil
  }

  func rows(query: String, appearance: AppearancePreferences) -> [ThemeCommandItem] {
    guard entered else { return [] }
    let dark = appearance.isDark
    let modeTitle = dark ? "切换为浅色主题" : "切换为深色主题"
    let back = ThemeCommandItem(id: "theme:back", title: "主题", description: nil, icon: "arrow.left",
      action: .back, selected: false, swatch: nil, searchText: "")
    let toggle = ThemeCommandItem(id: "theme:switch", title: modeTitle, description: nil,
      icon: dark ? "sun.max" : "moon", action: .switchMode, selected: false, swatch: nil,
      searchText: "theme \(modeTitle) toggle switch appearance dark light night 切换 外观 浅色 深色")
    let selected = dark ? appearance.codeThemes.dark : appearance.codeThemes.light
    let presets = CodeThemeCatalog.options(dark: dark).map { preset -> ThemeCommandItem in
      let seed = preset.variant(dark: dark)!.seed
      return .init(id: "theme:preset:" + preset.id, title: preset.label,
        description: dark ? "深色配色主题" : "浅色配色主题", icon: nil, action: .preset(preset.id),
        selected: selected == preset.id,
        swatch: .init(accent: seed.accent ?? "#339cff", foreground: seed.ink ?? (dark ? "#ffffff" : "#1a1c1f"),
          background: seed.surface ?? (dark ? "#181818" : "#ffffff")),
        searchText: "theme \(preset.label) color appearance preset 主题 颜色 外观 预设")
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let matcher = DesktopFuzzyQuery(trimmed)
    // The reference's Back row is force-mounted even when the search has no matches.
    return [back] + ([toggle] + presets).filter { trimmed.isEmpty || matcher.match($0.searchText) != nil }
  }

  /// Validate again against the current mode, then close even if persistence fails.
  @discardableResult func perform(_ id: String, store: WorkspaceStore, close: () -> Void) -> Bool {
    guard let row = rows(query: "", appearance: store.appearance).first(where: { $0.id == id }) else { return false }
    if row.action == .back { back(); return true }
    back()
    switch row.action {
    case .back: break
    case .switchMode:
      var value = store.appearance
      value.theme = value.isDark ? "light" : "dark"
      _ = store.commitAppearance(value)
    case .preset(let id): _ = store.selectCodeTheme(id, dark: store.appearance.isDark)
    }
    close()
    return true
  }
}
