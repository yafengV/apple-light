import AppKit
import SwiftUI

struct AppearanceVisualPaletteCard: View {
  @Bindable var store: WorkspaceStore
  let dark: Bool
  let showVariantTitle: Bool
  private var available: Bool { store.libraryLoaded && !store.restoringLibrary }
  private var title: String { dark ? "深色主题" : "浅色主题" }
  var body: some View {
    AppearanceSettingsCard {
      HStack(spacing: 8) {
        Text(showVariantTitle ? title : "主题").appFont(size: 13, weight: .medium).accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        AppearanceActionButton(title: "", label: "导入" + title, symbolName: "square.and.arrow.down",
          available: { available }, interactionAvailable: { !store.hasSettingsConfirmation }) { source in
            store.beginAppearanceImport(dark: dark, source: source, independentVariant: showVariantTitle)
          }.fixedSize().help("导入" + title)
          .settingsSearchTarget(.importTheme, when: !dark)
        AppearanceActionButton(title: "", label: "复制" + title, symbolName: "doc.on.doc",
          available: { available }, interactionAvailable: { !store.hasSettingsConfirmation }) { _ in
            do {
              try AppearanceThemeClipboard.copy(store.appearance, dark: dark, to: .general)
              store.notices.show(id: "appearance-theme-copy", title: "已复制" + title, level: .success)
            } catch {
              // sa's export callback reports success only; failed copies have no toast.
            }
          }.fixedSize().help("复制" + title)
          .settingsSearchTarget(.exportTheme, when: !dark)
        CodeThemePicker(store: store, dark: dark).settingsSearchTarget(dark ? .darkCodeTheme : .lightCodeTheme)
      }.padding(.horizontal, 16).padding(.vertical, 12).disabled(!available)
        .settingsSearchTarget(dark ? .darkThemeShare : .lightThemeShare)
      AppearanceSettingsDivider()
      AppearanceAccentPicker(store: store, dark: dark)
      AppearanceSettingsDivider()
      hexColorRow("背景色", key: \.background, dark: dark, value: store.appearance.themeShare(dark: dark).theme.surface)
      AppearanceSettingsDivider()
      hexColorRow("前景色", key: \.foreground, dark: dark, value: store.appearance.themeShare(dark: dark).theme.ink)
      AppearanceSettingsDivider()
      AppearanceFontPicker(store: store, role: .ui, dark: dark, controls: .family, rowTitle: "字体")
        .settingsSearchTarget(.uiFont, when: !dark).settingsSearchTarget(dark ? .darkUIFont : .lightUIFont)
    }.labeledContentStyle(AppearanceSettingsRowStyle())
      .accessibilityElement(children: .contain).accessibilityLabel(title)
  }
  private func hexColorRow(_ title: String, key: WritableKeyPath<AppearancePalette, String?>, dark: Bool, value: String) -> some View {
    LabeledContent(title) {
      AppearanceColorInput(value: value, label: (dark ? "深色" : "浅色") + title, available: { available }) {
        store.setAppearanceColor($0, key: key, dark: dark)
      }.frame(width: 136, height: 28).disabled(!available)
    }
  }
}
