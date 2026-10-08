import SwiftUI

private struct AppearanceLabelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var appearanceSettingsLabel: Bool {
    get { self[AppearanceLabelKey.self] }
    set { self[AppearanceLabelKey.self] = newValue }
  }
}

struct AppearanceSettingsRowStyle: LabeledContentStyle {
  var compact = true
  func makeBody(configuration: Configuration) -> some View {
    AppearanceSettingsRow(compact: compact) { configuration.content } label: { configuration.label }
  }
}

/// LabeledContent merges a multi-control native content area into its text
/// label. Use this row directly when both family/style or an editor/unit must
/// remain independently discoverable in the system accessibility tree.
struct AppearanceSettingsRow<Label: View, Content: View>: View {
  var compact = true
  @ViewBuilder var content: () -> Content
  @ViewBuilder var label: () -> Label
  var body: some View {
    HStack(spacing: compact ? 16 : 24) {
      label().appFont(size: 13, weight: .medium)
        .frame(maxWidth: .infinity, alignment: .leading)
      content().fixedSize(horizontal: true, vertical: false)
    }.padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
      .accessibilityElement(children: .contain)
  }
}

struct AppearanceSettingsCard<Content: View>: View {
  @Environment(\.appAppearance) private var appearance
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(spacing: 0) { content() }
      .background(appearance.resolvedColors["elevatedSecondary"].color)
      .clipShape(RoundedRectangle(cornerRadius: SettingsCardLayout.radius))
      .overlay(RoundedRectangle(cornerRadius: SettingsCardLayout.radius).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: SettingsCardLayout.borderWidth))
  }
}

struct AppearanceSettingsDivider: View {
  @Environment(\.appAppearance) private var appearance
  var body: some View { Rectangle().fill(appearance.resolvedColors["border"].color).frame(height: 0.5).padding(.horizontal, 16).accessibilityHidden(true) }
}
