import AppKit
import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: WorkspaceStore
  private struct ImportTarget: Identifiable { let dark: Bool; var id: String { dark ? "dark" : "light" } }
  @State private var importTarget: ImportTarget?
  @State private var status: String?

  var body: some View {
    VStack(spacing: 0) {
      if let error = store.generalSettingsError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
      }
      Form {
        Section("主题") {
          SettingsMenuPicker("基础主题", selection: binding(\.theme), options: [
            SettingsMenuOption(value: "system", title: "跟随系统"),
            SettingsMenuOption(value: "light", title: "浅色"),
            SettingsMenuOption(value: "dark", title: "深色")
          ]).settingsSearchTarget(.theme)
        }
        paletteSection("浅色主题", key: \.light, dark: false)
          .id("light-appearance-palette")
          .settingsSearchTarget(.lightPalette)
        paletteSection("深色主题", key: \.dark, dark: true)
          .id("dark-appearance-palette")
          .settingsSearchTarget(.darkPalette)
        Section("字号") {
          AppearanceFontSizeRow(store: store, kind: .ui)
          AppearanceFontSizeRow(store: store, kind: .code)
        }
        Section("交互") {
          SettingsToggle(title: "交互控件使用指针光标",
            description: "开启后，鼠标悬停在按钮和链接上会显示指针光标。", isOn: binding(\.usePointerCursors))
            .settingsSearchTarget(.pointer)
          SettingsSegmentedPicker(title: "差异标记", description: "使用颜色或 +/− 标记显示代码更改。",
            selection: binding(\.diffMarkerStyle), options: [
            SettingsSegmentOption(value: .color, title: "颜色", accessibilityLabel: "颜色差异标记"),
            SettingsSegmentOption(value: .symbols, title: "+/−", accessibilityLabel: "加减号差异标记")
          ])
          .settingsSearchTarget(.diffMarkers)
          SettingsSegmentedPicker(title: "减少动态效果", description: "减少界面动画，或跟随 macOS 辅助功能设置。",
            selection: binding(\.reduceMotion),
            options: ReduceMotionPreference.allCases.map {
              SettingsSegmentOption(value: $0, title: $0.title)
            })
          .settingsSearchTarget(.reduceMotion)
        }
        Section("当前主题预览") {
          VStack(alignment: .leading, spacing: 12) {
            Text("准备好开始了吗？").appFont(size: 19, weight: .semibold)
            Text("修改会立即生效。中文、English 与 0123456789。").appFont(size: 14)
            Text("let greeting = \"Hello, ShipiOS\"").appFont(size: 12, design: .monospaced)
            Label("主题预览", systemImage: "sparkle").foregroundStyle(store.appearance.accentColor)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .foregroundStyle(store.appearance.foregroundColor)
            .background(store.appearance.backgroundColor, in: RoundedRectangle(cornerRadius: 8))
        }
        Section {
          HStack {
            Spacer()
            Button("恢复默认外观") {
              store.appearance = AppearancePreferences()
              status = nil
            }
            .disabled(store.appearance == AppearancePreferences())
          }
          if let status { Text(status).appFont(.caption).textSelection(.enabled) }
        }
      }.settingsFormStyle().appSurface()
    }
      .sheet(item: $importTarget) { target in
        AppearanceThemeImportView(store: store, dark: target.dark, onClose: { importTarget = nil })
      }
  }

  private func binding<T>(_ key: WritableKeyPath<AppearancePreferences, T>) -> Binding<T> {
    Binding(
      get: { store.appearance[keyPath: key] },
      set: { value in
        var appearance = store.appearance
        appearance[keyPath: key] = value
        store.appearance = appearance
      })
  }
  private func paletteBinding<T>(
    _ palette: WritableKeyPath<AppearancePreferences, AppearancePalette>,
    _ value: WritableKeyPath<AppearancePalette, T>
  ) -> Binding<T> {
    Binding(
      get: { store.appearance[keyPath: palette][keyPath: value] },
      set: { newValue in
        var appearance = store.appearance
        appearance[keyPath: palette][keyPath: value] = newValue
        store.appearance = appearance
      })
  }

  private func paletteSection(
    _ title: String, key: WritableKeyPath<AppearancePreferences, AppearancePalette>, dark: Bool
  ) -> some View {
    let palette = store.appearance[keyPath: key]
    let colors = store.appearance.resolvedColors(dark: dark)
    let background = colors["surface"].color
    let foreground = colors["textForeground"].color
    return Section {
      paletteColorRow("强调色", palette: key, value: \.accent, fallback: colors["accent"].color)
      hexColorRow("背景色", key: \.background, dark: dark, value: store.appearance.themeShare(dark: dark).theme.surface)
      hexColorRow("前景色", key: \.foreground, dark: dark, value: store.appearance.themeShare(dark: dark).theme.ink)
      AppearanceFontPicker(store: store, role: .ui, dark: dark)
        .settingsSearchTarget(.uiFont, when: !dark)
        .settingsSearchTarget(dark ? .darkUIFont : .lightUIFont)
      AppearanceFontPicker(store: store, role: .content, dark: dark)
        .settingsSearchTarget(dark ? .darkContentFont : .lightContentFont)
      AppearanceFontPicker(store: store, role: .code, dark: dark)
        .settingsSearchTarget(.codeFont, when: !dark)
        .settingsSearchTarget(dark ? .darkCodeFont : .lightCodeFont)
      Toggle("半透明侧栏", isOn: paletteBinding(key, \.translucentSidebar))
      HStack {
        Text("对比度")
        Slider(value: paletteBinding(key, \.contrast), in: 0...100, step: 1)
        Text("\(Int(palette.contrast))").monospacedDigit().frame(width: 28, alignment: .trailing)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text(title).appFont(.headline)
        Text("ShipiOS 主题预览 · Aa 0123").appFont(.caption)
        Text("let ready = true").appFont(.caption, design: .monospaced)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .foregroundStyle(palette.foreground.flatMap(AppearancePreferences.color) ?? foreground)
        .background(
          store.appearance.paletteColor(
            palette.background, fallback: background, dark: dark),
          in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8).strokeBorder(
            colors["borderFocus"].color, lineWidth: 1))
    } header: {
      HStack {
        Text(title)
        Spacer(minLength: 8)
        HStack(spacing: 8) {
          Button("导入") { importTarget = .init(dark: dark) }
            .accessibilityLabel("导入" + title)
            .settingsSearchTarget(.importTheme, when: !dark)
          Button("复制主题") {
            do {
              try AppearanceThemeClipboard.copy(store.appearance, dark: dark, to: .general)
              status = "已复制" + title + "。"
            } catch { status = "复制失败：" + error.localizedDescription }
          }.accessibilityLabel("复制" + title).settingsSearchTarget(.exportTheme, when: !dark)
        }.disabled(!store.libraryLoaded).settingsSearchTarget(dark ? .darkThemeShare : .lightThemeShare)
        CodeThemePicker(store: store, dark: dark)
          .disabled(!store.libraryLoaded)
          .settingsSearchTarget(dark ? .darkCodeTheme : .lightCodeTheme)
      }
    }
  }
  private func hexColorRow(_ title: String, key: WritableKeyPath<AppearancePalette, String?>, dark: Bool, value: String) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: 8)
      AppearanceColorInput(value: value, label: (dark ? "深色" : "浅色") + title, available: { store.libraryLoaded }) {
        store.setAppearanceColor($0, key: key, dark: dark)
      }.frame(width: 136, height: 28).disabled(!store.libraryLoaded)
    }
  }
  private func paletteColorRow(
    _ title: String, palette: WritableKeyPath<AppearancePreferences, AppearancePalette>,
    value: WritableKeyPath<AppearancePalette, String?>, fallback: Color
  ) -> some View {
    let current = store.appearance[keyPath: palette][keyPath: value]
    return HStack {
      ColorPicker(
        title,
        selection: Binding(
          get: { current.flatMap(AppearancePreferences.color) ?? fallback },
          set: { _ = store.setAppearanceColor(AppearancePreferences.hex($0), key: value, dark: palette == \.dark) }),
        supportsOpacity: false)
      Text(current ?? "自动").appFont(.caption).foregroundStyle(.secondary)
      Button("重置") { _ = store.setAppearanceColor(nil, key: value, dark: palette == \.dark) }
        .disabled(current == nil).accessibilityLabel("重置" + title)
    }
  }
}
