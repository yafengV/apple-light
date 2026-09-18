import Foundation

enum DiffMarkerStyle: String, Codable, CaseIterable, Identifiable, Sendable {
  case color, symbols

  var id: String { rawValue }
  var title: String {
    switch self {
    case .color: "颜色"
    case .symbols: "+/−"
    }
  }
}

enum ReduceMotionPreference: String, Codable, CaseIterable, Identifiable, Sendable {
  case system, on, off

  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: "跟随系统"
    case .on: "开启"
    case .off: "关闭"
    }
  }

  func resolved(systemValue: Bool) -> Bool {
    switch self {
    case .system: systemValue
    case .on: true
    case .off: false
    }
  }
}

struct AppearancePalette: Codable, Equatable, Sendable {
  var accent: String?
  var background: String?
  var foreground: String?
  var translucentSidebar = true
  var contrast: Double

  static let light = Self(contrast: 45)
  static let dark = Self(contrast: 60)

  func normalized() -> Self {
    var value = self
    value.accent = AppearancePreferences.validHex(accent)
    value.background = AppearancePreferences.validHex(background)
    value.foreground = AppearancePreferences.validHex(foreground)
    value.contrast = contrast.isFinite ? min(100, max(0, contrast)) : 50
    return value
  }
}

struct AppearancePreferences: Codable, Equatable, Sendable {
  var theme = "system"
  var uiFont = ""
  var codeFont = ""
  var uiSize: Double = 13
  var codeSize: Double = 12
  var accent: String?
  var background: String?
  var foreground: String?
  var light = AppearancePalette.light
  var dark = AppearancePalette.dark
  var usePointerCursors = false
  var diffMarkerStyle = DiffMarkerStyle.color
  var reduceMotion = ReduceMotionPreference.system

  enum CodingKeys: String, CodingKey {
    case theme, uiFont, codeFont, uiSize, codeSize, accent, background, foreground
    case light, dark, usePointerCursors, diffMarkerStyle, reduceMotion
  }

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "system"
    uiFont = try values.decodeIfPresent(String.self, forKey: .uiFont) ?? ""
    codeFont = try values.decodeIfPresent(String.self, forKey: .codeFont) ?? ""
    uiSize = try values.decodeIfPresent(Double.self, forKey: .uiSize) ?? 13
    codeSize = try values.decodeIfPresent(Double.self, forKey: .codeSize) ?? 12
    accent = try values.decodeIfPresent(String.self, forKey: .accent)
    background = try values.decodeIfPresent(String.self, forKey: .background)
    foreground = try values.decodeIfPresent(String.self, forKey: .foreground)
    let migratedLight = AppearancePalette(
      accent: accent, background: background, foreground: foreground,
      translucentSidebar: true, contrast: 45)
    let migratedDark = AppearancePalette(
      accent: accent, background: background, foreground: foreground,
      translucentSidebar: true, contrast: 60)
    light = try values.decodeIfPresent(AppearancePalette.self, forKey: .light) ?? migratedLight
    dark = try values.decodeIfPresent(AppearancePalette.self, forKey: .dark) ?? migratedDark
    usePointerCursors = try values.decodeIfPresent(Bool.self, forKey: .usePointerCursors) ?? false
    diffMarkerStyle =
      try values.decodeIfPresent(DiffMarkerStyle.self, forKey: .diffMarkerStyle) ?? .color
    reduceMotion =
      try values.decodeIfPresent(ReduceMotionPreference.self, forKey: .reduceMotion) ?? .system
    self = normalized()
  }

  func normalized() -> Self {
    var value = self
    if !["system", "light", "dark"].contains(theme) { value.theme = "system" }
    value.uiSize = uiSize.isFinite ? min(20, max(11, uiSize)) : 13
    value.codeSize = codeSize.isFinite ? min(24, max(10, codeSize)) : 12
    value.uiFont = String(uiFont.prefix(200))
    value.codeFont = String(codeFont.prefix(200))
    value.accent = Self.validHex(accent)
    value.background = Self.validHex(background)
    value.foreground = Self.validHex(foreground)
    value.light = light.normalized()
    value.dark = dark.normalized()
    return value
  }
  static func validHex(_ value: String?) -> String? {
    guard let value else { return nil }
    let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard text.count == 6, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return "#" + text.uppercased()
  }
}

struct AppearanceThemeFile: Codable {
  let format: String
  let version: Int
  let appearance: AppearancePreferences

  init(appearance: AppearancePreferences) {
    format = "shipios-theme"
    version = 1
    self.appearance = appearance.normalized()
  }
  static func decode(_ data: Data) throws -> AppearancePreferences {
    guard data.count <= 65_536 else { throw AgentFailure(message: "主题文件不能超过 64 KiB。") }
    let file = try JSONDecoder().decode(Self.self, from: data)
    guard file.format == "shipios-theme", file.version == 1 else {
      throw AgentFailure(message: "不支持此主题文件格式或版本。")
    }
    return file.appearance.normalized()
  }
}
