import SwiftUI

struct CodeThemePicker: View {
  let store: WorkspaceStore
  let dark: Bool
  @State private var menu = CodeThemeMenuState()
  var body: some View {
    CodeThemeMenuButton(store: store, dark: dark, menu: menu)
      .frame(width: 176, height: 28)
    .onDisappear { menu.dismiss() }
  }
}

struct CodeThemeMenuContent: View {
  @Environment(\.appAppearance) private var appearance
  let store: WorkspaceStore
  let menu: CodeThemeMenuState
  let choose: (String) -> Void
  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(menu.options) { preset in
            Button { choose(preset.id) } label: {
              HStack(spacing: 8) {
                if let swatch = preset.swatch(dark: menu.dark) { ThemeColorSwatch(swatch: swatch) }
                Text(preset.label).appFont(size: 13).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if preset.id == (menu.dark ? store.appearance.codeThemes.dark : store.appearance.codeThemes.light) {
                  Image(systemName: "checkmark").font(.system(size: 12)).frame(width: 16)
                }
              }.padding(.horizontal, 8).frame(height: 34).contentShape(Rectangle())
            }.buttonStyle(.plain)
              .background(preset.id == menu.highlightedID ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color : .clear, in: RoundedRectangle(cornerRadius: 12))
              .searchResultPointer(enabled: menu.presented) { menu.hover(preset.id) }
              .onHover { if !$0, menu.highlightedID == preset.id { menu.hover(nil) } }
              .accessibilityLabel(preset.label)
              .accessibilityValue(preset.id == (menu.dark ? store.appearance.codeThemes.dark : store.appearance.codeThemes.light) ? "已选择" : "")
              .accessibilityIdentifier("code-theme-option:" + preset.id).id(preset.id)
          }
        }.padding(.bottom, 4)
      }.frame(maxHeight: 320)
        .onChange(of: menu.highlightedID) { _, id in if let id { reader.scrollTo(id) } }
    }
    .padding(4).frame(width: 240)
    .foregroundStyle(appearance.foregroundColor)
    .background(appearance.resolvedColors["controlBackgroundOpaque"].color.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(appearance.resolvedColors["border"].color, lineWidth: 0.5))
    .accessibilityElement(children: .contain).accessibilityLabel(menu.dark ? "深色代码主题" : "浅色代码主题")
  }
}
