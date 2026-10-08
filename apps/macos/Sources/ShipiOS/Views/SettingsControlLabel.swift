import SwiftUI

/// A setting's explanation belongs to its label, not to another form row.
struct SettingsControlLabel: View {
  @Environment(\.appearanceSettingsLabel) private var appearanceLabel
  let title: String
  var description: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsRowTypography.labelDescriptionGap) {
      Text(title).appFont(size: appearanceLabel ? 13 : SettingsRowTypography.labelSize, weight: .medium)
        .settingsTextLineHeight(text: title, fontSize: appearanceLabel ? 13 : SettingsRowTypography.labelSize,
          lineHeight: appearanceLabel ? 16 : SettingsRowTypography.labelLineHeight, weight: .medium)
      if let description, !description.isEmpty {
        Text(description).appFont(size: appearanceLabel ? 10 : SettingsRowTypography.descriptionSize)
          .foregroundStyle(.secondary)
          .settingsTextLineHeight(text: description, fontSize: appearanceLabel ? 10 : SettingsRowTypography.descriptionSize,
            lineHeight: appearanceLabel ? 12 : SettingsRowTypography.descriptionLineHeight)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .multilineTextAlignment(.leading)
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
