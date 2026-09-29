import Foundation

enum AppearanceMode: String, CaseIterable, Identifiable {
  case system, light, dark
  var id: String { rawValue }
  var title: String { switch self { case .system: "系统"; case .light: "浅色"; case .dark: "深色" } }
  var variants: [AppearanceMode] { self == .system ? [.light, .dark] : [self] }
  init(preference: String) { self = Self(rawValue: preference) ?? .system }
  func moved(by delta: Int) -> Self {
    let index = Self.allCases.firstIndex(of: self)!
    return Self.allCases[(index + delta + Self.allCases.count) % Self.allCases.count]
  }
}

/// The same five-line TypeScript example as the desktop Appearance page.
enum AppearanceDiffPreview {
  static let path = "src/theme-preview.ts"
  static let before = "const themePreview: ThemeConfig = {\n  surface: \"sidebar\",\n  accent: \"#2563eb\",\n  contrast: 42,\n};\n"
  static let after = "const themePreview: ThemeConfig = {\n  surface: \"sidebar-elevated\",\n  accent: \"#0ea5e9\",\n  contrast: 68,\n};\n"
  static let diff = ReviewDiff("@@ -1,5 +1,5 @@\n const themePreview: ThemeConfig = {\n-  surface: \"sidebar\",\n-  accent: \"#2563eb\",\n-  contrast: 42,\n+  surface: \"sidebar-elevated\",\n+  accent: \"#0ea5e9\",\n+  contrast: 68,\n };\n")
  static let left = diff.lines.filter { $0.oldLine != nil }
  static let right = diff.lines.filter { $0.newLine != nil }
}
