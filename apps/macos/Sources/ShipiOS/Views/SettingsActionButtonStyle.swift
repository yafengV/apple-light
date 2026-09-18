import SwiftUI

/// Settings actions participate in Tab navigation regardless of the system's
/// keyboard-navigation preference, like the reference app's HTML buttons.
struct SettingsActionButtonStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsActionButton(configuration: configuration)
  }
}

private struct SettingsActionButton: View {
  let configuration: PrimitiveButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focused: Bool

  var body: some View {
    Button(configuration)
      .buttonStyle(.bordered)
      .focusable(isEnabled)
      .focused($focused)
      .focusEffectDisabled()
      .overlay {
        if focused && isEnabled {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(appearance.accentColor, lineWidth: 2)
            .padding(-3).allowsHitTesting(false)
        }
      }
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard isEnabled, press.modifiers.isEmpty else { return .ignored }
        configuration.trigger()
        return .handled
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { focused = false }
      }
  }
}
