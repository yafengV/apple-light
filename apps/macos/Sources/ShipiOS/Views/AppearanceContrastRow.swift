import SwiftUI

struct AppearanceContrastRow: View {
  @Bindable var store: WorkspaceStore
  let dark: Bool
  var body: some View {
    LabeledContent("对比度") {
      AppearanceContrastSlider(value: Binding(
        get: { (dark ? store.appearance.dark : store.appearance.light).contrast },
        set: { value in
          guard store.libraryLoaded, !store.restoringLibrary else { return }
          var appearance = store.appearance
          if dark { appearance.dark.contrast = value } else { appearance.light.contrast = value }
          _ = store.commitAppearance(appearance)
        }), label: dark ? "深色 对比度" : "浅色 对比度", theme: store.appearance.themeShare(dark: dark).theme,
        available: { store.libraryLoaded && !store.restoringLibrary })
        .frame(width: 192, height: 36).disabled(!store.libraryLoaded || store.restoringLibrary)
    }
  }
}
