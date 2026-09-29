import AppKit
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: WorkspaceStore
  private struct ImportTarget: Identifiable { let dark: Bool; var id: String { dark ? "dark" : "light" } }
  @State private var importTarget: ImportTarget?
  @State private var status: String?
  private var available: Bool { store.libraryLoaded && !store.restoringLibrary }
  private var variants: [AppearanceMode] { AppearanceMode(preference: store.appearance.theme).variants }

  var body: some View {
    SettingsScrollPage(title: SettingsPage.appearance.title, actions: {}, controls: {}) {
      VStack(alignment: .leading, spacing: 40) {
        if let error = store.generalSettingsError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 0) {
          sectionTitle("主题")
          VStack(spacing: 16) {
            AppearanceModePicker(store: store).settingsSearchTarget(.theme)
            AppearanceCodePreview(appearance: store.appearance)
            VStack(spacing: 20) {
              ForEach(variants) { variant in
                paletteCard(dark: variant == .dark)
                  .id(variant.rawValue + "-appearance-palette")
                  .settingsSearchTarget(variant == .dark ? .darkPalette : .lightPalette)
              }
            }
          }
        }
        VStack(alignment: .leading, spacing: 0) {
          sectionTitle("偏好设置")
          preferences
        }
        if let status { Text(status).appFont(size: 12).foregroundStyle(.secondary).textSelection(.enabled) }
      }
    }
    .environment(\.appearanceSettingsLabel, true)
    .toggleStyle(SettingsSwitchStyle())
    .sheet(item: $importTarget) { target in
      AppearanceThemeImportView(store: store, dark: target.dark, onClose: { importTarget = nil })
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).appFont(size: 14, weight: .medium).accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.bottom, 6)
  }
  private var preferences: some View {
    AppearanceSettingsCard {
      SettingsToggle(title: "使用指针光标", description: "悬停交互元素时切换为指针光标",
        isOn: binding(\.usePointerCursors))
        .padding(.horizontal, 16).padding(.vertical, 12).settingsSearchTarget(.pointer)
      AppearanceSettingsDivider()
      SettingsSegmentedPicker(title: "减少动态效果", description: "减少动画效果或匹配系统设置",
        selection: binding(\.reduceMotion), options: ReduceMotionPreference.allCases.map {
          SettingsSegmentOption(value: $0, title: $0 == .system ? "系统" : $0.title)
        }).settingsSearchTarget(.reduceMotion)
      AppearanceSettingsDivider()
      AppearanceFontSizeRow(store: store, kind: .ui)
      AppearanceSettingsDivider()
      AppearanceFontSizeRow(store: store, kind: .code)
      AppearanceSettingsDivider()
      SettingsSegmentedPicker(title: "差异标记", description: "使用颜色或 +/− 标记显示更改",
        selection: binding(\.diffMarkerStyle), options: [
          SettingsSegmentOption(value: .color, title: "颜色", accessibilityLabel: "颜色差异标记"),
          SettingsSegmentOption(value: .symbols, title: "+/-", accessibilityLabel: "加号/减号差异标记")
        ]).settingsSearchTarget(.diffMarkers)
    }.labeledContentStyle(AppearanceSettingsRowStyle(compact: false)).disabled(!available)
  }

  private func binding<T>(_ key: WritableKeyPath<AppearancePreferences, T>) -> Binding<T> {
    Binding(get: { store.appearance[keyPath: key] }, set: { value in
      guard available else { return }
      var appearance = store.appearance; appearance[keyPath: key] = value; _ = store.commitAppearance(appearance)
    })
  }
  private func paletteBinding<T>(_ dark: Bool, _ value: WritableKeyPath<AppearancePalette, T>) -> Binding<T> {
    Binding(get: { (dark ? store.appearance.dark : store.appearance.light)[keyPath: value] }, set: { newValue in
      guard available else { return }
      var appearance = store.appearance
      if dark { appearance.dark[keyPath: value] = newValue } else { appearance.light[keyPath: value] = newValue }
      _ = store.commitAppearance(appearance)
    })
  }
  private func paletteCard(dark: Bool) -> some View {
    let title = dark ? "深色主题" : "浅色主题"
    return AppearanceSettingsCard {
      HStack(spacing: 8) {
        Text(title).appFont(size: 13, weight: .medium).accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button {
          guard available else { return }; importTarget = .init(dark: dark)
        } label: { Image(systemName: "square.and.arrow.down").font(.system(size: 14)).frame(width: 28, height: 28) }
          .buttonStyle(.plain).accessibilityLabel("导入" + title).help("导入" + title)
          .settingsSearchTarget(.importTheme, when: !dark)
        Button {
          guard available else { return }
          do { try AppearanceThemeClipboard.copy(store.appearance, dark: dark, to: .general); status = "已复制" + title + "。" }
          catch { status = "复制失败：" + error.localizedDescription }
        } label: { Image(systemName: "doc.on.doc").font(.system(size: 14)).frame(width: 28, height: 28) }
          .buttonStyle(.plain).accessibilityLabel("复制" + title).help("复制" + title)
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
      AppearanceFontPicker(store: store, role: .ui, dark: dark)
        .settingsSearchTarget(.uiFont, when: !dark).settingsSearchTarget(dark ? .darkUIFont : .lightUIFont)
      AppearanceSettingsDivider()
      AppearanceFontPicker(store: store, role: .content, dark: dark).settingsSearchTarget(dark ? .darkContentFont : .lightContentFont)
      AppearanceSettingsDivider()
      AppearanceFontPicker(store: store, role: .code, dark: dark)
        .settingsSearchTarget(.codeFont, when: !dark).settingsSearchTarget(dark ? .darkCodeFont : .lightCodeFont)
      AppearanceSettingsDivider()
      Toggle("半透明侧边栏", isOn: paletteBinding(dark, \.translucentSidebar))
        .appFont(size: 13, weight: .medium).padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityLabel(dark ? "深色 半透明侧边栏" : "浅色 半透明侧边栏").disabled(!available)
      AppearanceSettingsDivider()
      AppearanceContrastRow(store: store, dark: dark)
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
