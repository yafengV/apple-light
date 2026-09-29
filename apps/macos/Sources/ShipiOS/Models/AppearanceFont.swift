import Foundation

enum AppearanceFontRole: String, CaseIterable, Identifiable, Sendable {
  case ui, content, code
  var id: String { rawValue }
  var title: String { switch self { case .ui: "界面字体"; case .content: "内容字体"; case .code: "代码字体" } }
  var defaultTitle: String { self == .content ? "与界面字体相同" : "系统默认" }
}
struct AppearanceFontFace: Codable, Equatable, Sendable {
  let family: String
  let fullName: String
  let postscriptName: String
  var normalized: Self {
    .init(family: String(family.prefix(200)), fullName: String(fullName.prefix(200)), postscriptName: String(postscriptName.prefix(200)))
  }
}
extension AppearancePalette {
  func font(_ role: AppearanceFontRole) -> String? {
    switch role { case .ui: uiFont; case .content: contentFont; case .code: codeFont }
  }
  func fontFace(_ role: AppearanceFontRole) -> AppearanceFontFace? {
    switch role { case .ui: uiFace; case .content: contentFace; case .code: codeFace }
  }
  mutating func setFont(_ role: AppearanceFontRole, family: String?, face: AppearanceFontFace? = nil) {
    switch role {
    case .ui: uiFont = family; uiFace = face
    case .content: contentFont = family; contentFace = face
    case .code: codeFont = family; codeFace = face
    }
  }
}
extension AppearancePreferences {
  func fontFamily(_ role: AppearanceFontRole, dark: Bool) -> String {
    let palette = dark ? self.dark : light
    switch role {
    case .ui: return palette.uiFont ?? uiFont
    case .code: return palette.codeFont ?? codeFont
    case .content: return palette.contentFont.flatMap { $0.isEmpty ? nil : $0 } ?? fontFamily(.ui, dark: dark)
    }
  }
  func fontFace(_ role: AppearanceFontRole, dark: Bool) -> AppearanceFontFace? {
    let palette = dark ? self.dark : light
    if role == .content, palette.contentFont?.isEmpty != false { return palette.uiFace }
    return palette.fontFace(role)
  }
  func settingFont(_ role: AppearanceFontRole, family: String?, face: AppearanceFontFace? = nil, dark: Bool) -> Self {
    var value = self
    if dark { value.dark.setFont(role, family: family ?? "", face: face) }
    else { value.light.setFont(role, family: family ?? "", face: face) }
    return value.normalized()
  }
}
