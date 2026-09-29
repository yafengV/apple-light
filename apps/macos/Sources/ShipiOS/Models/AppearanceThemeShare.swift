import Foundation

/// The public theme text exchanged by the reference app, independent of the
/// older ShipiOS whole-appearance file format.
struct AppearanceThemeShare: Codable, Equatable, Sendable {
  static let prefix = "codex-theme-v1:"
  struct Fonts: Codable, Equatable, Sendable {
    var code: String?
    var ui: String?
    var content: String?
    var codeFace: AppearanceFontFace?
    var uiFace: AppearanceFontFace?
    var contentFace: AppearanceFontFace?
    enum CodingKeys: String, CodingKey { case code, ui, content, codeFace, uiFace, contentFace }
    init(code: String?, ui: String?, content: String?, codeFace: AppearanceFontFace?, uiFace: AppearanceFontFace?, contentFace: AppearanceFontFace?) {
      self.code = code; self.ui = ui; self.content = content
      self.codeFace = codeFace; self.uiFace = uiFace; self.contentFace = contentFace
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      for key in [CodingKeys.code, .ui] where !values.contains(key) {
        throw DecodingError.keyNotFound(key, .init(codingPath: decoder.codingPath, debugDescription: "Missing required font key"))
      }
      code = try values.decodeIfPresent(String.self, forKey: .code)
      ui = try values.decodeIfPresent(String.self, forKey: .ui)
      content = try values.decodeIfPresent(String.self, forKey: .content)
      codeFace = values.contains(.codeFace) ? try values.decode(AppearanceFontFace.self, forKey: .codeFace) : nil
      uiFace = values.contains(.uiFace) ? try values.decode(AppearanceFontFace.self, forKey: .uiFace) : nil
      contentFace = values.contains(.contentFace) ? try values.decode(AppearanceFontFace.self, forKey: .contentFace) : nil
    }
    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      if let code { try values.encode(code, forKey: .code) } else { try values.encodeNil(forKey: .code) }
      if let ui { try values.encode(ui, forKey: .ui) } else { try values.encodeNil(forKey: .ui) }
      try values.encodeIfPresent(content, forKey: .content)
      try values.encodeIfPresent(codeFace, forKey: .codeFace)
      try values.encodeIfPresent(uiFace, forKey: .uiFace)
      try values.encodeIfPresent(contentFace, forKey: .contentFace)
    }
  }
  struct Theme: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case accent, accentSource, contrast, fonts, ink, opaqueWindows, semanticColors, surface }
    struct SemanticColors: Codable, Equatable, Sendable { var diffAdded: String; var diffRemoved: String; var skill: String }
    var accent: String
    var accentSource: String?
    var contrast: Int
    var fonts: Fonts
    var ink: String
    var opaqueWindows: Bool
    var semanticColors: SemanticColors
    var surface: String
  }
  let codeThemeId: String
  let theme: Theme
  let variant: String

  static func decode(_ value: String, dark: Bool) throws -> Self {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 65_536, text.hasPrefix(prefix) else { throw AgentFailure(message: "不支持此主题分享格式。") }
    let payload = String(text.dropFirst(prefix.count))
    let json = payload.hasPrefix("{") ? payload : payload.removingPercentEncoding
    guard let json else { throw AgentFailure(message: "主题分享文本的编码无效。") }
    let result = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    guard result.variant == (dark ? "dark" : "light"), CodeThemeCatalog.preset(result.codeThemeId, dark: dark) != nil,
      (0...100).contains(result.theme.contrast),
      result.theme.accentSource == nil || ["custom", "chatgpt"].contains(result.theme.accentSource!),
      [result.theme.accent, result.theme.ink, result.theme.surface, result.theme.semanticColors.diffAdded,
       result.theme.semanticColors.diffRemoved, result.theme.semanticColors.skill].allSatisfy({
        $0.count == 7 && $0.hasPrefix("#") && $0.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
      }) else { throw AgentFailure(message: "主题分类、代码主题或颜色数据无效。") }
    return result
  }
  func encoded() throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.prefix + String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
extension AppearanceThemeShare.Theme {
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    accent = try values.decode(String.self, forKey: .accent)
    accentSource = values.contains(.accentSource) ? try values.decode(String.self, forKey: .accentSource) : nil
    contrast = try values.decode(Int.self, forKey: .contrast)
    fonts = try values.decode(AppearanceThemeShare.Fonts.self, forKey: .fonts)
    ink = try values.decode(String.self, forKey: .ink)
    opaqueWindows = try values.decode(Bool.self, forKey: .opaqueWindows)
    semanticColors = try values.decode(SemanticColors.self, forKey: .semanticColors)
    surface = try values.decode(String.self, forKey: .surface)
  }
}
extension AppearancePreferences {
  func themeShare(dark: Bool) -> AppearanceThemeShare {
    let value = normalized(), palette = dark ? value.dark : value.light
    func font(_ role: AppearanceFontRole) -> String? {
      let family = role == .content ? palette.contentFont : value.fontFamily(role, dark: dark)
      let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }
    return .init(codeThemeId: dark ? value.codeThemes.dark : value.codeThemes.light, theme: .init(
      accent: (palette.accent ?? value.accent ?? "#339cff").lowercased(), accentSource: palette.accentSource,
      contrast: Int(palette.contrast.rounded()), fonts: .init(code: font(.code), ui: font(.ui), content: font(.content),
        codeFace: font(.code) == nil ? nil : palette.codeFace, uiFace: font(.ui) == nil ? nil : palette.uiFace,
        contentFace: font(.content) == nil ? nil : palette.contentFace),
      ink: (palette.foreground ?? value.foreground ?? (dark ? "#ffffff" : "#1a1c1f")).lowercased(),
      opaqueWindows: !palette.translucentSidebar,
      semanticColors: .init(diffAdded: (palette.diffAdded ?? (dark ? "#40c977" : "#00a240")).lowercased(),
        diffRemoved: (palette.diffRemoved ?? (dark ? "#fa423e" : "#ba2623")).lowercased(),
        skill: (palette.skill ?? (dark ? "#ad7bf9" : "#924ff7")).lowercased()),
      surface: (palette.background ?? value.background ?? (dark ? "#181818" : "#ffffff")).lowercased()),
      variant: dark ? "dark" : "light")
  }
  func importingThemeShare(_ text: String, dark: Bool) throws -> Self {
    let share = try AppearanceThemeShare.decode(text, dark: dark), theme = share.theme
    var value = self
    var palette = AppearancePalette(accent: theme.accent, background: theme.surface, foreground: theme.ink,
      translucentSidebar: !theme.opaqueWindows, contrast: Double(theme.contrast), diffAdded: theme.semanticColors.diffAdded,
      diffRemoved: theme.semanticColors.diffRemoved, skill: theme.semanticColors.skill, accentSource: theme.accentSource)
    for role in AppearanceFontRole.allCases {
      let family: String?, face: AppearanceFontFace?
      switch role {
      case .ui: family = theme.fonts.ui; face = theme.fonts.uiFace
      case .content: family = theme.fonts.content; face = theme.fonts.contentFace
      case .code: family = theme.fonts.code; face = theme.fonts.codeFace
      }
      palette.setFont(role, family: family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", face: face)
    }
    if dark { value.dark = palette; value.codeThemes.dark = share.codeThemeId }
    else { value.light = palette; value.codeThemes.light = share.codeThemeId }
    return value.normalized()
  }
}
