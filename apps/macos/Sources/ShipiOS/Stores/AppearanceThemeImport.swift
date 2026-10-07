import AppKit

extension WorkspaceStore {
  var canOpenAppearanceImport: Bool {
    libraryLoaded && !restoringLibrary && destination == .settings && settingsPage == .appearance
      && !hasSettingsConfirmation && presentedOverlay == nil
  }
  func beginAppearanceImport(dark: Bool, source: NSView? = nil, independentVariant: Bool = false) {
    guard canOpenAppearanceImport,
      (independentVariant && source?.window != nil) || AppearanceMode(preference: appearance.theme).variants.contains(dark ? .dark : .light),
      source == nil || (source?.window != nil && source?.window?.attachedSheet == nil) else { return }
    appearanceThemeImport = AppearanceThemeImportSession(dark: dark, independentMode: independentVariant ? appearance.theme : nil)
  }
  func canEditAppearanceImport(_ session: AppearanceThemeImportSession) -> Bool {
    appearanceThemeImport === session && libraryLoaded && !restoringLibrary
      && destination == .settings && settingsPage == .appearance
      && session.allows(theme: appearance.theme)
  }
  func dismissAppearanceImport(_ session: AppearanceThemeImportSession) {
    guard appearanceThemeImport === session else { return }
    session.value = ""; appearanceThemeImport = nil
    // ua has no DialogTrigger; its actual modal close handler prevents default
    // autofocus and has no triggerRef to focus. Do not invent a return target.
  }
  @discardableResult func submitAppearanceImport(_ session: AppearanceThemeImportSession) -> Bool {
    guard canEditAppearanceImport(session) else { return false }
    let previousError = generalSettingsError
    guard session.valid, importThemeShare(session.value, dark: session.dark) else {
      // The reference reports import errors as a toast, keeping the input intact.
      generalSettingsError = previousError
      notices.show(id: "appearance-theme-import", title: "无法导入 \(session.variantLabel) 主题", level: .error)
      return false
    }
    let label = session.variantLabel
    dismissAppearanceImport(session)
    notices.show(id: "appearance-theme-import", title: "已导入 \(label) 主题", level: .success)
    return true
  }
}
