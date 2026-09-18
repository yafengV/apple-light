import SwiftUI

struct SettingsSegmentOption<Value: Hashable> {
  let value: Value
  let title: String
  var accessibilityLabel: String? = nil
}

/// The reference uses independently focusable pressed buttons, not a radio group.
struct SettingsSegmentedPicker<Value: Hashable>: View {
  let title: String
  var description: String? = nil
  @Binding var selection: Value
  let options: [SettingsSegmentOption<Value>]

  var body: some View {
    LabeledContent {
      HStack(spacing: 2) {
        ForEach(options, id: \.value) { option in
          SettingsSegmentButton(option: option, selected: selection == option.value) {
            if selection != option.value { selection = option.value }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        description == nil ? dimensions[.firstTextBaseline] : dimensions[VerticalAlignment.center]
      }
    } label: {
      SettingsControlLabel(title: title, description: description)
    }
  }
}

private struct SettingsSegmentButton<Value: Hashable>: View {
  let option: SettingsSegmentOption<Value>
  let selected: Bool
  let onSelect: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focused: Bool
  @State private var hovered = false

  var body: some View {
    Button(action: activate) {
      Text(option.title)
        .appFont(.body)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(appearance.foregroundColor)
        .background(appearance.foregroundColor.opacity(
          selected ? (hovered ? 0.18 : 0.12) : (hovered ? 0.06 : 0)),
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
      .buttonStyle(.plain)
      .accessibilityLabel(option.accessibilityLabel ?? option.title)
      .accessibilityAddTraits(selected ? .isSelected : [])
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
        activate()
        return .handled
      }
      .onChange(of: isEnabled) { _, enabled in
        if !enabled { focused = false; hovered = false }
      }
  }

  private func activate() {
    // Keep this on the original Button action: accessibility activation can
    // bypass an action introduced only inside a PrimitiveButtonStyle.
    guard isEnabled else { return }
    focused = true
    onSelect()
  }
}
