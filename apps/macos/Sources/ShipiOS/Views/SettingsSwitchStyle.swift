import SwiftUI

/// Settings switches share the reference app's dimensions and focus treatment.
/// The binding remains owned by the setting, including validation and persistence.
struct SettingsSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    SettingsSwitchRow(isOn: configuration.$isOn, label: configuration.label)
  }
}

private struct SettingsSwitchRow<Label: View>: View {
  @Binding var isOn: Bool
  let label: Label
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @Environment(\.settingsMinimumControlWidth) private var reservesControlWidth
  @FocusState private var focused: Bool
  @State private var keyboardFocus = true

  var body: some View {
    SettingsLabeledRow(reservesControlWidth: reservesControlWidth) { label } control: {
      SettingsSwitchSurface(isOn: isOn, isEnabled: isEnabled, focused: focused && keyboardFocus)
        .animation(appearance.shouldReduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture {
          guard isEnabled else { return }
          keyboardFocus = false
          focused = true
          isOn.toggle()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusable(isEnabled).focused($focused).focusEffectDisabled()
    .settingsFocusReveal(focused: focused)
    .onKeyPress(keys: [.space, .return], phases: .down) { press in
      guard isEnabled, press.modifiers.isEmpty else { return .ignored }
      keyboardFocus = true
      isOn.toggle()
      return .handled
    }
    .onKeyPress(phases: .down) { press in
      if press.modifiers.intersection([.command, .control, .option]).isEmpty { keyboardFocus = true }
      return .ignored
    }
    .onChange(of: focused) { _, value in if !value { keyboardFocus = true } }
    .onChange(of: isEnabled) { _, enabled in if !enabled { focused = false } }
    .accessibilityRepresentation {
      Toggle(isOn: $isOn) { label }.toggleStyle(.switch).disabled(!isEnabled)
    }
  }
}
