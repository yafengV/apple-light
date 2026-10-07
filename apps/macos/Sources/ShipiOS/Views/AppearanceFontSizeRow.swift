import SwiftUI

struct AppearanceFontSizeRow: View {
  @Bindable var store: WorkspaceStore
  let kind: AppearanceFontSize
  var body: some View {
    AppearanceSettingsRow(compact: false) {
      HStack(spacing: 8) {
        AppearanceFontSizeInput(kind: kind, value: Binding(
          get: { kind.value(in: store.appearance) },
          set: { value in
            var appearance = store.appearance
            if kind == .ui { appearance.uiSize = value } else { appearance.codeSize = value }
            _ = store.commitAppearance(appearance)
          }))
          .frame(width: 64, height: 28)
          // The reference number input is keyed by its committed preference.
          .id(kind.value(in: store.appearance))
        Text("px").appFont(size: 13).foregroundStyle(.secondary)
      }
    } label: {
      SettingsControlLabel(title: kind.title, description: kind.description)
    }
    .disabled(!store.libraryLoaded || store.restoringLibrary)
    .settingsSearchTarget(kind == .ui ? .uiFontSize : .codeFontSize)
  }
}
