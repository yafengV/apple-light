import AppKit
import SwiftUI

struct CodeThemeMenuButton: View {
  let store: WorkspaceStore
  let dark: Bool
  let menu: CodeThemeMenuState
  typealias Control = SettingsPopupMenuButton.Control
  static func placement(anchor: NSRect, viewport: NSRect, height: CGFloat) -> NSRect? {
    SettingsPopupMenuButton.placement(anchor: anchor, viewport: viewport, height: height)
  }
  var body: some View {
    SettingsPopupMenuButton(
      title: CodeThemeCatalog.preset(dark ? store.appearance.codeThemes.dark : store.appearance.codeThemes.light, dark: dark)?.label ?? "Codex",
      label: dark ? "深色代码主题" : "浅色代码主题", menu: menu,
      menuHeight: { min(320, CGFloat(menu.options.count * 34 + 4)) + 8 },
      available: store.libraryLoaded && !store.restoringLibrary,
      open: { menu.open(dark: dark, keyboard: $0) }, choose: { menu.choose($0, store: store) },
      content: { AnyView(CodeThemeMenuContent(store: store, menu: menu, choose: $0)) })
  }
}
