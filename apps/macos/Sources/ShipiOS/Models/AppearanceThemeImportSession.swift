import Foundation
import Observation

@Observable final class AppearanceThemeImportSession: Identifiable {
  let id = UUID()
  let dark: Bool
  var value = ""
  var valid: Bool { (try? AppearanceThemeShare.decode(value, dark: dark)) != nil }
  var variantLabel: String { dark ? "深色" : "浅色" }
  init(dark: Bool) { self.dark = dark }
}
