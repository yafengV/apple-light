import SwiftUI

enum SettingsPageLayout {
  static let contentWidth: CGFloat = 768
  static let horizontalInset: CGFloat = 20
  static let viewportWidth = contentWidth + horizontalInset * 2
  static let headingSize: CGFloat = 24
  static let headingContentSpacing: CGFloat = 32
  static let sectionSpacing: CGFloat = 40
}

enum SettingsCardLayout {
  static let sectionHeadingSize: CGFloat = 14
  static let sectionHeaderMinHeight: CGFloat = 46
  static let sectionHeaderBottomInset: CGFloat = 6
  static let radius: CGFloat = 16
  static let borderWidth: CGFloat = 1
  static let dividerInset: CGFloat = 16
  static let dividerHeight: CGFloat = 1
  static let rowHorizontalInset: CGFloat = 16
  static let rowVerticalInset: CGFloat = 12
  static let rowGap: CGFloat = 24
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

/// The heading and cards belong to one scroll document. Older systems retain
/// the grouped form until section decomposition is available.
struct SettingsForm<Content: View>: View {
  @Environment(\.settingsPageTitle) private var title
  @Environment(\.settingsFormEmbedded) private var embedded
  @ViewBuilder var content: () -> Content

  @ViewBuilder var body: some View {
    if embedded {
      Form { content().environment(\.settingsPageTitle, nil) }
        .formStyle(.columns).toggleStyle(SettingsSwitchStyle())
        .buttonStyle(SettingsActionButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    } else if #available(macOS 15.0, *) {
      SettingsScrollPage(title: title ?? "", actions: {}, controls: {}) {
        Group(sections: content().labeledContentStyle(SettingsFormLabeledContentStyle())) { sections in
          ForEach(sections) { section in
            SettingsFormSection(section: section)
          }
        }
      }
      .toggleStyle(SettingsSwitchStyle())
      .buttonStyle(SettingsActionButtonStyle())
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
        content().environment(\.settingsPageTitle, nil)
      }
      .formStyle(.grouped)
      .toggleStyle(SettingsSwitchStyle())
      .buttonStyle(SettingsActionButtonStyle())
      .contentMargins(.horizontal, SettingsPageLayout.horizontalInset, for: .scrollContent)
    }
  }
}

/// Keep the original controls, while the page owns its card geometry. Field
/// labels are explicit so changing the container cannot turn them into hints.
@available(macOS 15.0, *)
private struct SettingsFormSection: View {
  @Environment(\.appAppearance) private var appearance
  let section: SectionConfiguration
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !section.header.isEmpty {
        ForEach(section.header) { header in
          header.appFont(size: SettingsCardLayout.sectionHeadingSize, weight: .medium).textCase(nil)
            .frame(maxWidth: .infinity, minHeight: SettingsCardLayout.sectionHeaderMinHeight, alignment: .leading)
            .padding(.bottom, SettingsCardLayout.sectionHeaderBottomInset)
            .accessibilityAddTraits(.isHeader)
        }
      }
      if !section.content.isEmpty {
        AppearanceSettingsCard {
          ForEach(section.content) { row in
            row
              .labeledContentStyle(SettingsFormLabeledContentStyle())
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, SettingsCardLayout.rowHorizontalInset)
              .padding(.vertical, SettingsCardLayout.rowVerticalInset)
              .overlay(alignment: .bottom) {
                if row.id != section.content.last?.id {
                  Rectangle().fill(appearance.resolvedColors["border"].color)
                    .frame(height: SettingsCardLayout.dividerHeight)
                    .padding(.horizontal, SettingsCardLayout.dividerInset)
                    .accessibilityHidden(true)
                }
              }
          }
        }
      }
      if !section.footer.isEmpty {
        ForEach(section.footer) { footer in
          footer.appFont(size: 12).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 6)
        }
      }
    }
  }
}

private struct SettingsFormLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: SettingsCardLayout.rowGap) {
      configuration.label.frame(maxWidth: .infinity, alignment: .leading)
      configuration.content.fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
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
        if !title.isEmpty {
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
              Text(title).appFont(size: SettingsPageLayout.headingSize)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("settings-page-heading")
              if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            actions()
          }.padding(.top, SettingsPageLayout.horizontalInset)
            .padding(.bottom, SettingsPageLayout.headingContentSpacing)
        }
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
      }.padding(.top, title.isEmpty ? SettingsPageLayout.horizontalInset : 0)
        .padding(.horizontal, SettingsPageLayout.horizontalInset)
        .padding(.bottom, SettingsPageLayout.horizontalInset)
    }
    .environment(\.settingsPageTitle, nil)
    .environment(\.settingsFormEmbedded, true)
    .background(appearance.backgroundColor)
  }
}

extension View {
  func settingsFormStyle() -> some View {
    toggleStyle(SettingsSwitchStyle()).buttonStyle(SettingsActionButtonStyle())
  }
}
