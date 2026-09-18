import SwiftUI

/// The reference uses independently focusable pressed buttons, not a radio group.
struct SettingsSegmentedPicker<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [(value: Value, title: String)]

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 2) {
        ForEach(options, id: \.value) { option in
          Button(option.title) {
            if selection != option.value { selection = option.value }
          }
          .buttonStyle(SettingsSegmentButtonStyle(selected: selection == option.value))
          .accessibilityAddTraits(selection == option.value ? .isSelected : [])
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
    }
  }
}

private struct SettingsSegmentButtonStyle: PrimitiveButtonStyle {
  let selected: Bool

  func makeBody(configuration: Configuration) -> some View {
    SettingsSegmentButton(configuration: configuration, selected: selected)
  }
}

private struct SettingsSegmentButton: View {
  let configuration: PrimitiveButtonStyleConfiguration
  let selected: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focused: Bool
  @State private var hovered = false

  var body: some View {
    Button(action: configuration.trigger) {
      configuration.label
        .appFont(.body)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(appearance.foregroundColor)
        .background(appearance.foregroundColor.opacity(
          selected ? (hovered ? 0.18 : 0.12) : (hovered ? 0.06 : 0)),
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
      .buttonStyle(.plain)
      .opacity(isEnabled ? 1 : 0.4)
      .focusable(isEnabled).focused($focused).focusEffectDisabled()
      .overlay {
        if focused && isEnabled {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(appearance.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
      .onHover { hovered = $0 && isEnabled }
      .onKeyPress(keys: [.space, .return], phases: .down) { press in
        guard isEnabled, press.modifiers.isEmpty else { return .ignored }
        configuration.trigger()
        return .handled
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { focused = false; hovered = false }
      }
  }
}
