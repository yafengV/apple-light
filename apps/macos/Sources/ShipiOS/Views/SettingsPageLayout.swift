import SwiftUI

enum SettingsPageLayout {
  static let contentWidth: CGFloat = 768
  static let horizontalInset: CGFloat = 20
  static let viewportWidth = contentWidth + horizontalInset * 2
  static let headingSize: CGFloat = 24
  static let headingContentSpacing: CGFloat = 32
  static let sectionSpacing: CGFloat = 40
}

extension SettingsPage {
  var usesScrollingFormHeader: Bool {
    switch self {
    case .appearance, .plugins, .mcpServers, .skills, .connections, .shortcuts, .archived, .memories, .hooks: false
    default: true
    }
  }
}

private struct SettingsPageTitleKey: EnvironmentKey {
  static let defaultValue: String? = nil
}
private struct SettingsFormEmbeddedKey: EnvironmentKey {
  static let defaultValue = false
}
extension EnvironmentValues {
  var settingsFormEmbedded: Bool {
    get { self[SettingsFormEmbeddedKey.self] }
    set { self[SettingsFormEmbeddedKey.self] = newValue }
  }
  var settingsPageTitle: String? {
    get { self[SettingsPageTitleKey.self] }
    set { self[SettingsPageTitleKey.self] = newValue }
  }
}

/// The heading belongs to the same scroll document as the settings rows. An
/// empty section header avoids introducing a grouped card around the title.
struct SettingsPageFormStyle: FormStyle {
  let title: String?
  var embedded = false
  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    if embedded {
      Form { configuration.content.environment(\.settingsPageTitle, nil) }
        .formStyle(.columns).toggleStyle(SettingsSwitchStyle())
        .buttonStyle(SettingsActionButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Form {
        if let title {
          Section {} header: {
            Text(title).appFont(size: SettingsPageLayout.headingSize)
              .foregroundStyle(.primary).textCase(nil)
              .padding(.bottom, SettingsPageLayout.headingContentSpacing)
              .accessibilityAddTraits(.isHeader)
              .accessibilityIdentifier("settings-page-heading")
          }
        }
        configuration.content.environment(\.settingsPageTitle, nil)
      }
      .formStyle(.grouped)
      .toggleStyle(SettingsSwitchStyle())
      .buttonStyle(SettingsActionButtonStyle())
      .contentMargins(.horizontal, SettingsPageLayout.horizontalInset, for: .scrollContent)
    }
  }
}

private struct SettingsFormModifier: ViewModifier {
  @Environment(\.settingsPageTitle) private var title
  @Environment(\.settingsFormEmbedded) private var embedded
  func body(content: Content) -> some View {
    content.formStyle(SettingsPageFormStyle(title: title, embedded: embedded))
  }
}

/// A single scroll document; only the optional search/filter controls pin.
struct SettingsScrollPage<Actions: View, Controls: View, Content: View>: View {
  @Environment(\.appAppearance) private var appearance
  let title: String
  var subtitle: String? = nil
  var pinsControls = false
  @ViewBuilder var actions: () -> Actions
  @ViewBuilder var controls: () -> Controls
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text(title).appFont(size: SettingsPageLayout.headingSize)
              .accessibilityAddTraits(.isHeader).accessibilityIdentifier("settings-page-heading")
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
          }.frame(maxWidth: .infinity, alignment: .leading)
          actions()
        }.padding(.top, SettingsPageLayout.horizontalInset)
          .padding(.bottom, SettingsPageLayout.headingContentSpacing)
        Section {
          VStack(alignment: .leading, spacing: SettingsPageLayout.sectionSpacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, pinsControls ? 20 : 0)
        } header: {
          if pinsControls {
            controls().padding(.vertical, 8).frame(maxWidth: .infinity)
              .background(appearance.backgroundColor)
          }
        }
      }.padding(.horizontal, SettingsPageLayout.horizontalInset)
        .padding(.bottom, SettingsPageLayout.horizontalInset)
    }
    .environment(\.settingsPageTitle, nil)
    .environment(\.settingsFormEmbedded, true)
    .background(appearance.backgroundColor)
  }
}

extension View {
  func settingsFormStyle() -> some View { modifier(SettingsFormModifier()) }
}
