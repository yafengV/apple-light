import Foundation

extension WorkspaceStore {
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
      appearanceHandler?(value)
      return true
    } catch { generalSettingsError = error.localizedDescription; return false }
  }
}
