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
    HStack(spacing: compact ? 16 : 24) {
      configuration.label.appFont(size: 13, weight: .medium)
        .frame(maxWidth: .infinity, alignment: .leading)
      configuration.content.fixedSize(horizontal: true, vertical: false)
    }.padding(.horizontal, 16).padding(.vertical, compact ? 8 : 12)
  }
}

struct AppearanceSettingsCard<Content: View>: View {
  @Environment(\.appAppearance) private var appearance
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(spacing: 0) { content() }
      .background(appearance.resolvedColors["elevatedSecondary"].color)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 1))
  }
}

struct AppearanceSettingsDivider: View {
  @Environment(\.appAppearance) private var appearance
  var body: some View { Rectangle().fill(appearance.resolvedColors["border"].color).frame(height: 0.5).padding(.horizontal, 16).accessibilityHidden(true) }
}
