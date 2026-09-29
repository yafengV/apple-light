import SwiftUI

struct AppearanceAccentPicker: View {
  @Bindable var store: WorkspaceStore
  let dark: Bool
  @State private var menu = AppearanceAccentMenuState()
  private var selection: AppearanceAccentSelection {
    .init(source: store.appearance.themeShare(dark: dark).theme.accentSource, dark: dark)
  }
  var body: some View {
    LabeledContent("强调色") {
      HStack(spacing: 8) {
        SettingsPopupMenuButton(title: selection.title, label: dark ? "深色强调色" : "浅色强调色", menu: menu,
          buttonWidth: 144, fontSize: 13, menuWidth: 220,
          menuHeight: { menu.height(fontSize: store.appearance.nativeFont(size: 13).pointSize) },
          available: store.libraryLoaded && !store.restoringLibrary,
          open: { menu.open(dark: dark, keyboard: $0, store: store) },
          choose: { menu.choose($0, store: store) },
          content: { AnyView(AppearanceAccentMenuContent(menu: menu, selectedID: selection.selectedID, choose: $0)) })
          .frame(width: 144, height: 28)
        if selection.isCustom {
          AppearanceColorInput(value: store.appearance.themeShare(dark: dark).theme.accent, label: selection.customLabel,
            available: { store.libraryLoaded && !store.restoringLibrary }) {
            store.setAppearanceColor($0, key: \.accent, dark: dark)
          }.frame(width: 136, height: 28).disabled(!store.libraryLoaded || store.restoringLibrary)
        }
      }
    }.onDisappear { menu.dismiss() }
  }
}

struct AppearanceAccentMenuContent: View {
  @Environment(\.appAppearance) private var appearance
  let menu: AppearanceAccentMenuState
  let selectedID: String
  let choose: (String) -> Void
  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(menu.options) { option in
            Button { choose(option.id) } label: {
              HStack(spacing: 6) {
                HStack(spacing: 8) {
                  if let color = option.swatch {
                    Circle().fill(color.color).overlay(Circle().strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 1)).frame(width: 12, height: 12)
                  }
                  Text(option.title).appFont(size: 13).lineLimit(1)
                }
                Spacer(minLength: 4)
                if option.id == selectedID { Image(systemName: "checkmark").font(.system(size: 12)).frame(width: 12).opacity(option.enabled && option.id == menu.highlightedID ? 1 : 0.75) }
              }.padding(.horizontal, 8).frame(height: AppearanceAccentMenuState.rowHeight(fontSize: appearance.nativeFont(size: 13).pointSize)).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!option.enabled)
              .opacity(option.enabled ? 1 : 0.5)
              .background(option.enabled && option.id == menu.highlightedID ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color : .clear, in: RoundedRectangle(cornerRadius: 12))
              .searchResultPointer(enabled: option.enabled && menu.presented) { menu.hover(option.id) }
              .onHover { if !$0, menu.highlightedID == option.id { menu.hover(nil) } }
              .accessibilityLabel(option.title).accessibilityValue(option.id == selectedID ? "已选择" : "")
              .accessibilityIdentifier("appearance-accent-option:" + option.id).id(option.id)
          }
        }
      }.onChange(of: menu.highlightedID) { _, id in if let id { reader.scrollTo(id) } }
    }
    .padding(4).frame(width: 220)
    .foregroundStyle(appearance.foregroundColor)
    .background(appearance.resolvedColors["controlBackgroundOpaque"].color.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(appearance.resolvedColors["border"].color, lineWidth: 0.5))
    .accessibilityElement(children: .contain).accessibilityLabel(menu.dark ? "深色强调色" : "浅色强调色")
  }
}
