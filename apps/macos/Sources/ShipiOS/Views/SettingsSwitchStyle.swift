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
  @State private var spacePressed = false
  @State private var valueAction = SettingsSwitchValueAction()

  var body: some View {
    let _ = valueAction.update($isOn, enabled: isEnabled)
    SettingsLabeledRow(reservesControlWidth: reservesControlWidth) { label } control: {
      SettingsSwitchSurface(isOn: isOn, isEnabled: isEnabled, focused: focused && keyboardFocus)
        .animation(appearance.shouldReduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture {
          guard isEnabled else { return }
          spacePressed = false
          keyboardFocus = false
          focused = true
          valueAction.toggle()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusable(isEnabled).focused($focused).focusEffectDisabled()
    .settingsFocusReveal(focused: focused)
    .background(SettingsKeyReleaseCancellation { if spacePressed { spacePressed = false } })
    .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { press in
      guard isEnabled, focused,
        press.modifiers.intersection([.command, .control, .option]).isEmpty else {
        spacePressed = false
        return .ignored
      }
      keyboardFocus = true
      if press.phase == .up {
        let activate = spacePressed
        spacePressed = false
        if activate { valueAction.toggle() }
      } else {
        // A repeat key-down can establish :active on a newly focused button.
        spacePressed = true
      }
      return .handled
    }
    .onKeyPress(keys: [.return, KeyEquivalent("\u{3}")], phases: [.down, .repeat]) { press in
      guard isEnabled, focused,
        press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
      keyboardFocus = true; valueAction.toggle()
      return .handled
    }
    .onKeyPress(phases: .down) { press in
      if press.modifiers.intersection([.command, .control, .option]).isEmpty { keyboardFocus = true }
      return .ignored
    }
    .onChange(of: focused) { _, value in if !value { keyboardFocus = true; spacePressed = false } }
    .onChange(of: isEnabled) { _, enabled in if !enabled { focused = false; spacePressed = false } }
    .onAppear { valueAction.update($isOn, enabled: isEnabled) }
    .onDisappear { spacePressed = false; valueAction.clear() }
    .accessibilityRepresentation {
      Toggle(isOn: $isOn) { label }.toggleStyle(.switch).disabled(!isEnabled)
    }
  }
}

/// SwiftUI retains the original key-down callback for repeat events. Keep only
/// the current binding here, so those events do not read an old Toggle snapshot.
@MainActor private final class SettingsSwitchValueAction {
  private var binding: Binding<Bool>?
  func update(_ binding: Binding<Bool>, enabled: Bool) { self.binding = enabled ? binding : nil }
  func toggle() { binding?.wrappedValue.toggle() }
  func clear() { binding = nil }
}
