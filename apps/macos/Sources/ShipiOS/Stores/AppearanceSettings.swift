import Foundation

extension WorkspaceStore {
  @discardableResult func setAppearanceColor(_ color: String?, key: WritableKeyPath<AppearancePalette, String?>, dark: Bool) -> Bool {
    var value = appearance
    var palette = dark ? value.dark : value.light
    palette[keyPath: key] = color
    if key == \.accent { palette.accentSource = color == nil ? nil : "custom" }
    if dark { value.dark = palette } else { value.light = palette }
    return commitAppearance(value)
  }
  @discardableResult func setAppearanceFont(_ role: AppearanceFontRole, family: String?, face: AppearanceFontFace? = nil, dark: Bool) -> Bool {
    commitAppearance(appearance.settingFont(role, family: family, face: face, dark: dark))
  }
  @discardableResult func importThemeShare(_ text: String, dark: Bool) -> Bool {
    do { return commitAppearance(try appearance.importingThemeShare(text, dark: dark)) }
    catch { generalSettingsError = error.localizedDescription; return false }
  }
  var appearance: AppearancePreferences {
    get { library.appearance ?? AppearancePreferences() }
    set {
      _ = commitAppearance(newValue)
    }
  }
  @discardableResult func selectCodeTheme(_ id: String, dark: Bool) -> Bool {
    guard let value = appearance.selectingCodeTheme(id, dark: dark) else {
      generalSettingsError = "此代码主题不支持当前浅色或深色分类。"; return false
    }
    return commitAppearance(value)
  }
  @discardableResult func commitAppearance(_ value: AppearancePreferences) -> Bool {
    let value = value.normalized()
    guard value != appearance else { return true }
    guard libraryLoaded else { generalSettingsError = "工作区尚未完成加载，请稍后再修改。"; return false }
    do {
      var candidate = library; candidate.appearance = value
      try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
      library = candidate; generalSettingsError = nil
      if let session = appearanceThemeImport,
        !AppearanceMode(preference: value.theme).variants.contains(session.dark ? .dark : .light) {
        dismissAppearanceImport(session)
      }
      appearanceHandler?(value)
      return true
    } catch { generalSettingsError = error.localizedDescription; return false }
  }
}
