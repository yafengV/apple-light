import Foundation

struct CodeThemePair: Codable, Equatable, Hashable, Sendable {
  var light = "codex"
  var dark = "codex"
  init(light: String = "codex", dark: String = "codex") { self.light = light; self.dark = dark }
  func normalized() -> Self {
    .init(light: CodeThemeCatalog.preset(light, dark: false)?.id ?? "codex",
      dark: CodeThemeCatalog.preset(dark, dark: true)?.id ?? "codex")
  }
}
struct CodeThemePreset: Decodable, Identifiable, Sendable {
  struct Seed: Decodable, Sendable {
    struct SemanticColors: Decodable, Sendable { let diffAdded: String?; let diffRemoved: String?; let skill: String? }
    let accent: String?
    let contrast: Double?
    let ink: String?
    let surface: String?
    let opaqueWindows: Bool?
    let semanticColors: SemanticColors?
    let fonts: [String: String?]?
  }
  struct Variant: Decodable, Sendable {
    let themeName: String
    let foreground: String
    let background: String
    let seed: Seed
    let patch: Seed
  }
  let id: String
  let label: String
  let variants: [String: Variant]
  func variant(dark: Bool) -> Variant? { variants[dark ? "dark" : "light"] }
}
enum CodeThemeCatalog {
  private struct Catalog: Decodable { let presets: [CodeThemePreset] }
  static let presets: [CodeThemePreset] = {
    let url: URL
    if Bundle.main.bundleURL.pathExtension == "app" {
      url = Bundle.main.resourceURL!.appendingPathComponent("ShipiOS_ShipiOS.bundle/SyntaxHighlighting/theme-catalog.json")
    } else { url = Bundle.module.bundleURL.appendingPathComponent("SyntaxHighlighting/theme-catalog.json") }
    return (try? JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)).presets) ?? []
  }()
  static func options(dark: Bool) -> [CodeThemePreset] { presets.filter { $0.variant(dark: dark) != nil } }
  static func preset(_ id: String, dark: Bool) -> CodeThemePreset? {
    presets.first { $0.id == id && $0.variant(dark: dark) != nil }
  }
}
