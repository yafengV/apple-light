import Foundation
import Observation

@Observable final class AppearanceThemeImportSession: Identifiable {
  let id = UUID()
  let dark: Bool
  let independentMode: String?
  var value = ""
  var valid: Bool { (try? AppearanceThemeShare.decode(value, dark: dark)) != nil }
  var variantLabel: String { dark ? "深色" : "浅色" }
  init(dark: Bool, independentMode: String? = nil) {
    self.dark = dark; self.independentMode = independentMode
  }
  func allows(theme: String) -> Bool {
    if let independentMode { return theme == independentMode }
    return AppearanceMode(preference: theme).variants.contains(dark ? .dark : .light)
  }
}
