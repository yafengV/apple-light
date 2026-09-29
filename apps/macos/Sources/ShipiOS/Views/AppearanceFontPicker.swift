import SwiftUI

struct AppearanceFontPicker: View {
  @Bindable var store: WorkspaceStore
  let role: AppearanceFontRole
  let dark: Bool
  private var palette: AppearancePalette { dark ? store.appearance.dark : store.appearance.light }
  private var value: String {
    role == .content ? palette.contentFont ?? "" : store.appearance.fontFamily(role, dark: dark)
  }
  private var family: AppearanceFontCatalog.Family? { AppearanceFontCatalog.family(value, code: role == .code) }
  private var variant: String { dark ? "深色" : "浅色" }
  private var selection: String { family.map { AppearanceFontCatalog.quote($0.name) } ?? value }
  private var options: [SettingsMenuOption<String>] {
    var choices: [SettingsMenuOption<String>] = [.init(value: "", title: role.defaultTitle)]
    choices += AppearanceFontCatalog.options(code: role == .code).map { .init(value: AppearanceFontCatalog.quote($0.name), title: $0.name) }
    if !selection.isEmpty, !choices.contains(where: { $0.value == selection }) { choices.insert(.init(value: selection, title: value), at: 1) }
    return choices
  }
  var body: some View {
    LabeledContent(role.title) {
      HStack(spacing: 8) {
        SettingsMenuInput(title: variant + role.title, selection: Binding(get: { selection }, set: {
          _ = store.setAppearanceFont(role, family: $0.isEmpty ? nil : $0, dark: dark)
        }), options: options)
          .frame(maxWidth: 180)
        SettingsMenuInput(title: variant + role.title + "样式", selection: Binding(
          get: { palette.fontFace(role)?.postscriptName ?? family?.faces.first?.value.postscriptName ?? "" },
          set: { name in
            guard let family, let face = family.faces.first(where: { $0.value.postscriptName == name }) else { return }
            _ = store.setAppearanceFont(role, family: AppearanceFontCatalog.quote(family.name),
              face: face == family.faces.first ? nil : face.value, dark: dark)
          }), options: family?.faces.map { .init(value: $0.value.postscriptName, title: $0.style) } ?? [.init(value: "", title: "常规")])
          .frame(maxWidth: 150).disabled(family == nil || value.isEmpty)
      }
    }.disabled(!store.libraryLoaded)
  }
}
