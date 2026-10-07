import Observation

/// Navigation state only: revealing both saved palettes never edits either theme.
@MainActor @Observable final class AppearancePagePresentation {
  var advancedExpanded: Bool
  var separateModes = false

  init(advancedExpanded: Bool = false) { self.advancedExpanded = advancedExpanded }

  func variants(theme: String, systemDark: Bool) -> [AppearanceMode] {
    separateModes ? [.light, .dark] : [Self.effectiveVariant(theme: theme, systemDark: systemDark)]
  }

  nonisolated static func effectiveVariant(theme: String, systemDark: Bool) -> AppearanceMode {
    theme == "dark" || (theme == "system" && systemDark) ? .dark : .light
  }
}
