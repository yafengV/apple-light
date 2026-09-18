import SwiftUI

/// A setting's explanation belongs to its label, not to another form row.
struct SettingsControlLabel: View {
  let title: String
  var description: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).appFont(.body, weight: .medium)
      if let description, !description.isEmpty {
        Text(description).appFont(.caption, weight: .regular).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .multilineTextAlignment(.leading)
    .padding(.vertical, description == nil ? 0 : 4)
    .alignmentGuide(.firstTextBaseline) { dimensions in
      description == nil ? dimensions[.firstTextBaseline] : dimensions[VerticalAlignment.center]
    }
  }
}

struct SettingsToggle: View {
  let title: String
  let description: String
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      SettingsControlLabel(title: title, description: description)
    }
    .accessibilityLabel(title)
    .accessibilityHint(description)
  }
}
