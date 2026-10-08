import SwiftUI

/// A section owns its card on every supported macOS version. The original
/// controls retain their identity when rows appear, disappear or reorder.
struct SettingsSection<Header: View, Content: View, Footer: View>: View {
  private let header: Header
  private let content: Content
  private let footer: Footer
  private let hasHeader: Bool
  private let hasFooter: Bool
  @Environment(\.appAppearance) private var appearance

  init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
    @ViewBuilder footer: () -> Footer) {
    self.content = content(); self.header = header(); self.footer = footer()
    hasHeader = true; hasFooter = true
  }

  private init(header: Header, content: Content, footer: Footer, hasHeader: Bool, hasFooter: Bool) {
    self.header = header; self.content = content; self.footer = footer
    self.hasHeader = hasHeader; self.hasFooter = hasFooter
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if hasHeader {
        header.appFont(size: SettingsCardLayout.sectionHeadingSize, weight: .medium).textCase(nil)
          .frame(maxWidth: .infinity, minHeight: SettingsCardLayout.sectionHeaderMinHeight, alignment: .leading)
          .padding(.bottom, SettingsCardLayout.sectionHeaderBottomInset)
          .accessibilityAddTraits(.isHeader)
      }
      AppearanceSettingsCard {
        content
          .labeledContentStyle(SettingsFormLabeledContentStyle())
          .environment(\.settingsMinimumControlWidth, true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, SettingsCardLayout.rowHorizontalInset)
          .padding(.vertical, SettingsCardLayout.rowVerticalInset)
          .anchorPreference(key: SettingsRowBoundsKey.self, value: .bounds) { [$0] }
      }
      .overlayPreferenceValue(SettingsRowBoundsKey.self) { anchors in
        GeometryReader { proxy in
          let bounds = anchors.map { proxy[$0] }.sorted { $0.minY < $1.minY }
          ForEach(0..<max(0, bounds.count - 1), id: \.self) { index in
            Rectangle().fill(appearance.resolvedColors["border"].color)
              .frame(width: max(0, proxy.size.width - 2 * SettingsCardLayout.dividerInset),
                height: SettingsCardLayout.dividerHeight)
              .position(x: proxy.size.width / 2, y: bounds[index].maxY - SettingsCardLayout.dividerHeight / 2)
          }
        }.allowsHitTesting(false).accessibilityHidden(true)
      }
      .transformPreference(SettingsRowBoundsKey.self) { $0 = [] }
      if hasFooter {
        footer.appFont(size: SettingsRowTypography.descriptionSize).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.top, 6)
      }
    }
  }
}

extension SettingsSection where Header == EmptyView, Footer == EmptyView {
  init(@ViewBuilder content: () -> Content) {
    self.init(header: EmptyView(), content: content(), footer: EmptyView(), hasHeader: false, hasFooter: false)
  }
}
extension SettingsSection where Header == Text, Footer == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(header: Text(title), content: content(), footer: EmptyView(), hasHeader: true, hasFooter: false)
  }
}
extension SettingsSection where Footer == EmptyView {
  init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.init(header: header(), content: content(), footer: EmptyView(), hasHeader: true, hasFooter: false)
  }
}
extension SettingsSection where Header == EmptyView {
  init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.init(header: EmptyView(), content: content(), footer: footer(), hasHeader: false, hasFooter: true)
  }
}

private struct SettingsRowBoundsKey: PreferenceKey {
  static let defaultValue: [Anchor<CGRect>] = []
  static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
    value += nextValue()
  }
}
