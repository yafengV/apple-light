import SwiftUI

/// Settings switches share the reference app's dimensions and keyboard behavior.
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
  @Environment(\.layoutDirection) private var direction
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focused: Bool

  private var blue: Color {
    appearance.accentHex == nil ? Color(red: 0.2, green: 156.0 / 255, blue: 1) : appearance.accentColor
  }

  var body: some View {
    HStack {
      label
      Spacer(minLength: 12)
      Capsule()
        .fill(isOn ? blue : appearance.foregroundColor.opacity(0.1))
        .frame(width: 32, height: 20)
        .overlay(alignment: .leading) {
          Circle().fill(.white)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .frame(width: 16, height: 16)
            .offset(x: (isOn ? 14 : 2) * (direction == .rightToLeft ? -1 : 1))
        }
        .overlay {
          if focused && isEnabled {
            Capsule().strokeBorder(appearance.accentColor, lineWidth: 2)
              .padding(-3)
          }
        }
        .opacity(isEnabled ? 1 : 0.6)
        .animation(appearance.shouldReduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        .contentShape(Capsule())
        .onTapGesture {
          guard isEnabled else { return }
          focused = true
          isOn.toggle()
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .focusable(isEnabled).focused($focused).focusEffectDisabled()
    .onKeyPress(keys: [.space, .return], phases: .down) { press in
      guard isEnabled, press.modifiers.isEmpty else { return .ignored }
      isOn.toggle()
      return .handled
    }
    .onChange(of: isEnabled) { _, enabled in if !enabled { focused = false } }
    .accessibilityRepresentation {
      Toggle(isOn: $isOn) { label }.toggleStyle(.switch).disabled(!isEnabled)
    }
  }
}
