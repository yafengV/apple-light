import SwiftUI

struct AppearanceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var presentation: AppearancePagePresentation
  @Environment(\.colorScheme) private var colorScheme
  private var available: Bool { store.libraryLoaded && !store.restoringLibrary }
  private var variants: [AppearanceMode] {
    presentation.variants(theme: store.appearance.theme, systemDark: colorScheme == .dark)
  }

  init(store: WorkspaceStore, presentation: AppearancePagePresentation? = nil) {
    self.store = store
    _presentation = State(initialValue: presentation ?? AppearancePagePresentation(
      advancedExpanded: store.settingsSearchRequest?.result.page == .appearance))
  }

  var body: some View {
    SettingsScrollPage(title: SettingsPage.appearance.title, actions: {}, controls: {}) {
      VStack(alignment: .leading, spacing: 40) {
        if let error = store.generalSettingsError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 16) {
          sectionTitle("视觉风格")
          AppearanceSettingsCard {
            AppearanceSettingsRow(compact: false) {
              AppearanceModePicker(store: store).frame(width: 272).settingsSearchTarget(.theme)
            } label: { Text("模式") }
          }
          ForEach(variants) { variant in
            AppearanceVisualPaletteCard(store: store, dark: variant == .dark, showVariantTitle: variants.count > 1)
              .id(variant.rawValue + "-appearance-visual")
              .settingsSearchTarget(variant == .dark ? .darkPalette : .lightPalette)
          }
        }
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            AppearanceActionButton(title: "高级", label: "高级", symbolName: presentation.advancedExpanded ? "chevron.up" : "chevron.down",
              accessibilityValue: presentation.advancedExpanded ? "已展开" : "已折叠", available: { true },
              interactionAvailable: { !store.hasSettingsConfirmation }) { _ in
                presentation.advancedExpanded.toggle()
              }.fixedSize().settingsSearchTarget(.appearanceAdvanced)
            Spacer()
            if presentation.separateModes || store.appearance.hasAdvancedChanges {
              AppearanceActionButton(title: "重置为默认设置", label: "重置高级外观设置", available: { available },
                interactionAvailable: { !store.hasSettingsConfirmation }) { _ in
                  presentation.separateModes = false
                  _ = store.commitAppearance(store.appearance.resettingAdvanced())
                }.fixedSize()
            }
          }.frame(minHeight: 52)
          if presentation.advancedExpanded {
            AppearanceAdvancedSection(store: store, presentation: presentation, variants: variants)
          }
        }
      }
    }
    .environment(\.appearanceSettingsLabel, true)
    .toggleStyle(SettingsSwitchStyle())
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).appFont(size: 14, weight: .medium).accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
  }
}
