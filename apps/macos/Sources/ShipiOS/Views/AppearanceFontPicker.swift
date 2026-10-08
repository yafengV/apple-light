import SwiftUI

struct AppearanceFontPicker: View {
  @Bindable var store: WorkspaceStore
  let role: AppearanceFontRole
  let dark: Bool
  enum Controls { case family, style, both }
  var controls = Controls.both
  var rowTitle: String?
  var catalog: AppearanceFontCatalogSource = .shared
  @State private var familyMenu = AppearanceFontMenuState(.family)
  @State private var styleMenu = AppearanceFontMenuState(.style)
  private var palette: AppearancePalette { dark ? store.appearance.dark : store.appearance.light }
  private var value: String { role == .content ? palette.contentFont ?? "" : store.appearance.fontFamily(role, dark: dark) }
  private var selection: AppearanceFontSelection {
    // The existing store uses an empty string for a cleared/default override.
    AppearanceFontSelection(value: value.isEmpty ? nil : value, face: palette.fontFace(role), role: role, families: catalog.families)
  }
  private var resolved: (family: AppearanceFontCatalog.Family, face: AppearanceFontCatalog.Face)? { selection.resolved }
  private var label: String { selection.title }
  private var variant: String { dark ? "深色" : "浅色" }
  private var available: Bool { catalog.loaded && store.libraryLoaded && !store.restoringLibrary }
  private var styleAvailable: Bool { available && selection.styleEnabled }
  var body: some View {
    AppearanceSettingsRow {
      if !catalog.loaded { ProgressView().controlSize(.mini).task { await catalog.load() } }
      else {
        AppearanceControlsLayout {
          if controls != .style {
            button(familyMenu, title: label, label: variant + role.title, width: 240, enabled: available)
          }
          if controls != .family {
            button(styleMenu, title: resolved?.face.style ?? "常规", label: variant + role.title + "样式", width: 208, enabled: styleAvailable)
          }
        }
      }
    } label: { Text(rowTitle ?? role.title) }
    .onDisappear { familyMenu.dismiss(); styleMenu.dismiss() }
  }
  private func button(_ menu: AppearanceFontMenuState, title: String, label: String, width: CGFloat, enabled: Bool) -> some View {
    SettingsPopupMenuButton(title: title, label: label, menu: menu, fitsTitle: true, fontSize: 12, menuWidth: width, formStyle: .font,
      menuHeight: { menu.height }, available: enabled,
      open: { keyboard in
        (menu.kind == .family ? styleMenu : familyMenu).dismiss()
        menu.open(role: role, value: value, face: palette.fontFace(role), families: catalog.families, keyboard: keyboard)
      }, choose: { menu.choose($0, role: role, dark: dark, value: value, face: palette.fontFace(role), families: catalog.families, store: store) },
      content: { AnyView(AppearanceFontMenuContent(menu: menu, width: width, label: label,
        selectedID: menu.kind == .style ? resolved.map { "face:" + $0.face.value.postscriptName } : resolved.map { "family:" + $0.family.name } ?? (selection.selectedDefault ? "default" : nil), choose: $0)) })
      .disabled(!enabled)
  }
}

struct AppearanceFontMenuContent: View {
  @Environment(\.appAppearance) private var appearance
  let menu: AppearanceFontMenuState
  let width: CGFloat
  let label: String
  let selectedID: String?
  let choose: (String) -> Void
  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(spacing: 0) {
          ForEach(menu.options) { option in
            if option.id == "custom" { AppearanceCustomFontInput(menu: menu, label: label, apply: { choose("custom") }).frame(height: 28) }
            Button { choose(option.id) } label: {
              HStack(spacing: 6) {
                Text(option.title).appFont(size: 13).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if option.id == selectedID { Image(systemName: "checkmark").font(.system(size: 12)).frame(width: 16) }
              }.padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
              .background(option.id == menu.highlightedID ? appearance.resolvedColors["buttonSecondaryBackgroundHover"].color : .clear, in: RoundedRectangle(cornerRadius: 12))
              .searchResultPointer(enabled: menu.presented) { menu.hover(option.id) }
              .onHover { if !$0, menu.highlightedID == option.id { menu.hover(nil) } }
              .accessibilityLabel(option.title).accessibilityValue(option.id == selectedID ? "已选择" : "")
              .accessibilityIdentifier("appearance-font-option:" + option.id).id(option.id)
            if option.id == "default" { Rectangle().fill(appearance.resolvedColors["border"].color).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4) }
          }
        }
      }.onChange(of: menu.highlightedID) { _, id in if let id { reader.scrollTo(id) } }
    }
    .padding(4).frame(width: width)
    .foregroundStyle(appearance.foregroundColor)
    .background(appearance.resolvedColors["controlBackgroundOpaque"].color.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(appearance.resolvedColors["border"].color, lineWidth: 0.5))
    .accessibilityElement(children: .contain).accessibilityLabel(label)
  }
}
