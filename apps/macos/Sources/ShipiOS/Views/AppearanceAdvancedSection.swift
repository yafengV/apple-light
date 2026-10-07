import SwiftUI

struct AppearanceAdvancedSection: View {
  @Bindable var store: WorkspaceStore
  @Bindable var presentation: AppearancePagePresentation
  let variants: [AppearanceMode]
  private var available: Bool { store.libraryLoaded && !store.restoringLibrary }

  var body: some View {
    VStack(spacing: 16) {
      AppearanceSettingsCard {
        AppearanceFontSizeRow(store: store, kind: .ui)
        AppearanceSettingsDivider()
        AppearanceFontSizeRow(store: store, kind: .code)
      }
      AppearanceSettingsCard {
        SettingsSegmentedPicker(title: "减少动态效果", description: "减少动画效果或匹配系统设置",
          selection: binding(\.reduceMotion), options: ReduceMotionPreference.allCases.map {
            SettingsSegmentOption(value: $0, title: $0 == .system ? "系统" : $0.title)
          }).settingsSearchTarget(.reduceMotion)
        AppearanceSettingsDivider()
        SettingsToggle(title: "分别设置浅色和深色模式", description: "分别选择各自的主题、颜色和字体",
          isOn: $presentation.separateModes)
          .padding(.horizontal, 16).padding(.vertical, 12).settingsSearchTarget(.appearanceSeparateModes)
      }.labeledContentStyle(AppearanceSettingsRowStyle(compact: false))
      ForEach(variants) { variant in
        advancedPalette(dark: variant == .dark).id(variant.rawValue + "-appearance-advanced")
      }
      AppearanceSettingsCard {
        SettingsSegmentedPicker(title: "差异标记", description: "使用颜色或 +/− 标记显示更改",
          selection: binding(\.diffMarkerStyle), options: [
            SettingsSegmentOption(value: .color, title: "颜色", accessibilityLabel: "颜色差异标记"),
            SettingsSegmentOption(value: .symbols, title: "+/-", accessibilityLabel: "加号/减号差异标记")
          ]).settingsSearchTarget(.diffMarkers)
        AppearanceSettingsDivider()
        SettingsToggle(title: "使用指针光标", description: "悬停交互元素时切换为指针光标",
          isOn: binding(\.usePointerCursors))
          .padding(.horizontal, 16).padding(.vertical, 12).settingsSearchTarget(.pointer)
        AppearanceSettingsDivider()
        AppearanceSettingsRow(compact: false) {
          AppearanceDockIconPicker(store: store).frame(width: 104, height: 48).settingsSearchTarget(.dockIcon)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Dock 图标").appFont(size: 13, weight: .medium)
            Text("选择应用在 Dock 中使用的图标").appFont(size: 12).foregroundStyle(.secondary)
          }
        }
        AppearanceSettingsDivider()
        SettingsToggle(title: "字体平滑", description: "使用 macOS 原生字体抗锯齿",
          isOn: binding(\.useFontSmoothing))
          .padding(.horizontal, 16).padding(.vertical, 12).settingsSearchTarget(.fontSmoothing)
      }.labeledContentStyle(AppearanceSettingsRowStyle(compact: false))
    }.disabled(!available)
  }

  private func advancedPalette(dark: Bool) -> some View {
    AppearanceSettingsCard {
      if variants.count > 1 {
        Text(dark ? "深色主题" : "浅色主题").appFont(size: 13, weight: .medium)
          .accessibilityAddTraits(.isHeader).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16).padding(.vertical, 12)
        AppearanceSettingsDivider()
      }
      AppearanceFontPicker(store: store, role: .ui, dark: dark, controls: .style, rowTitle: "界面字体样式")
        .settingsSearchTarget(dark ? .darkUIFontStyle : .lightUIFontStyle)
      AppearanceSettingsDivider()
      AppearanceFontPicker(store: store, role: .content, dark: dark)
        .settingsSearchTarget(dark ? .darkContentFont : .lightContentFont)
      AppearanceSettingsDivider()
      AppearanceFontPicker(store: store, role: .code, dark: dark)
        .settingsSearchTarget(.codeFont, when: !dark).settingsSearchTarget(dark ? .darkCodeFont : .lightCodeFont)
      AppearanceSettingsDivider()
      Toggle("半透明侧边栏", isOn: paletteBinding(dark, \.translucentSidebar))
        .appFont(size: 13, weight: .medium).padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityLabel(dark ? "深色 半透明侧边栏" : "浅色 半透明侧边栏")
      AppearanceSettingsDivider()
      AppearanceContrastRow(store: store, dark: dark)
    }.labeledContentStyle(AppearanceSettingsRowStyle())
      .accessibilityElement(children: .contain)
  }
  private func binding<T>(_ key: WritableKeyPath<AppearancePreferences, T>) -> Binding<T> {
    Binding(get: { store.appearance[keyPath: key] }, set: { value in
      guard available else { return }
      var appearance = store.appearance; appearance[keyPath: key] = value; _ = store.commitAppearance(appearance)
    })
  }
  private func paletteBinding<T>(_ dark: Bool, _ key: WritableKeyPath<AppearancePalette, T>) -> Binding<T> {
    Binding(get: { (dark ? store.appearance.dark : store.appearance.light)[keyPath: key] }, set: { value in
      guard available else { return }
      var appearance = store.appearance
      if dark { appearance.dark[keyPath: key] = value } else { appearance.light[keyPath: key] = value }
      _ = store.commitAppearance(appearance)
    })
  }
}
