import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var selectingCodeFont: Bool?
  @State private var importing = false
  @State private var exporting = false
  @State private var status: String?

  var body: some View {
    Form {
      Section("主题") {
        SettingsMenuPicker("基础主题", selection: binding(\.theme), options: [
          SettingsMenuOption(value: "system", title: "跟随系统"),
          SettingsMenuOption(value: "light", title: "浅色"),
          SettingsMenuOption(value: "dark", title: "深色")
        ]).settingsSearchTarget(.theme)
      }
      paletteSection("浅色主题", key: \.light, dark: false)
        .settingsSearchTarget(.lightPalette)
      paletteSection("深色主题", key: \.dark, dark: true)
        .settingsSearchTarget(.darkPalette)
      Section("字体") {
        fontRow("界面字体", code: false).settingsSearchTarget(.uiFont)
        Stepper("界面字号：\(Int(store.appearance.uiSize))", value: binding(\.uiSize), in: 11...20).settingsSearchTarget(.uiFontSize)
        fontRow("代码字体", code: true).settingsSearchTarget(.codeFont)
        Stepper("代码字号：\(Int(store.appearance.codeSize))", value: binding(\.codeSize), in: 10...24).settingsSearchTarget(.codeFontSize)
        Text("代码字体同时用于代码块、文件预览、审查与终端。").appFont(.caption).foregroundStyle(.secondary)
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
          Button("导入主题…") { importing = true }.settingsSearchTarget(.importTheme)
          Button("导出主题…") { exporting = true }.settingsSearchTarget(.exportTheme)
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
      .sheet(
        isPresented: Binding(
          get: { selectingCodeFont != nil }, set: { if !$0 { selectingCodeFont = nil } })
      ) {
        FontSelectionView(
          code: selectingCodeFont == true,
          selection: selectingCodeFont == true ? binding(\.codeFont) : binding(\.uiFont))
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        do {
          let url = try result.get()
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          let data = try handle.read(upToCount: 65_537) ?? Data()
          store.appearance = try AppearanceThemeFile.decode(data)
          status = "已导入主题。"
        } catch { status = "导入失败：" + error.localizedDescription }
      }
      .fileExporter(
        isPresented: $exporting, document: ThemeDocument(appearance: store.appearance),
        contentType: .json, defaultFilename: "ShipiOS-theme"
      ) { result in
        switch result {
        case .success: status = "已导出主题。"
        case .failure(let error): status = "导出失败：" + error.localizedDescription
        }
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
    let background = dark
      ? Color(.sRGB, red: 0.095, green: 0.095, blue: 0.095, opacity: 1) : .white
    let foreground = dark ? Color.white : Color(.sRGB, white: 0.05, opacity: 1)
    return Section(title) {
      paletteColorRow("强调色", palette: key, value: \.accent, fallback: .blue)
      paletteColorRow("背景色", palette: key, value: \.background, fallback: background)
      paletteColorRow("前景色", palette: key, value: \.foreground, fallback: foreground)
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
            palette.accent.flatMap(AppearancePreferences.color) ?? .blue, lineWidth: 1))
    }
  }
  private func fontRow(_ title: String, code: Bool) -> some View {
    LabeledContent(title) {
      Button {
        selectingCodeFont = code
      } label: {
        let family = code ? store.appearance.codeFont : store.appearance.uiFont
        Text(family.isEmpty ? "系统默认" : family)
      }.accessibilityLabel("选择" + title)
        .accessibilityValue(
          (code ? store.appearance.codeFont : store.appearance.uiFont).isEmpty
            ? "系统默认" : (code ? store.appearance.codeFont : store.appearance.uiFont))
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
          set: { paletteBinding(palette, value).wrappedValue = AppearancePreferences.hex($0) }),
        supportsOpacity: false)
      Text(current ?? "自动").appFont(.caption).foregroundStyle(.secondary)
      Button("重置") { paletteBinding(palette, value).wrappedValue = nil }
        .disabled(current == nil).accessibilityLabel("重置" + title)
    }
  }
}

private struct ThemeDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.json]
  let appearance: AppearancePreferences
  init(appearance: AppearancePreferences) { self.appearance = appearance }
  init(configuration: ReadConfiguration) throws {
    appearance = try AppearanceThemeFile.decode(configuration.file.regularFileContents ?? Data())
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return FileWrapper(
      regularFileWithContents: try encoder.encode(AppearanceThemeFile(appearance: appearance)))
  }
}

private struct FontSelectionView: View {
  let code: Bool
  @Binding var selection: String
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var families = NSFontManager.shared.availableFontFamilies.sorted()
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(code ? "选择代码字体" : "选择界面字体").appFont(.title2, weight: .semibold)
      TextField("搜索已安装字体", text: $query).textFieldStyle(.roundedBorder)
      List {
        choice("", title: "系统默认")
        ForEach(
          families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) },
          id: \.self
        ) { family in
          choice(family, title: family)
        }
      }
      HStack {
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(20).frame(width: 440, height: 440)
  }
  private func choice(_ family: String, title: String) -> some View {
    Button {
      selection = family
      dismiss()
    } label: {
      HStack {
        Text(title)
        Spacer()
        if family == selection { Image(systemName: "checkmark") }
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(title)
      .accessibilityAddTraits(family == selection ? .isSelected : [])
  }
}
