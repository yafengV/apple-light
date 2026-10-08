import SwiftUI

enum SettingsRowTypography {
  static let labelSize: CGFloat = 13
  static let descriptionSize: CGFloat = 12
  static let labelDescriptionGap: CGFloat = 2
  static let labelLineHeight: CGFloat = 130.0 / 7
  static let descriptionLineHeight: CGFloat = 16
}

private struct SettingsMinimumControlWidthKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var settingsMinimumControlWidth: Bool {
    get { self[SettingsMinimumControlWidthKey.self] }
    set { self[SettingsMinimumControlWidthKey.self] = newValue }
  }
}

/// The control occupies its natural width, inside a trailing area whose minimum
/// is bounded by the row's content width. Layout measures before placing, so
/// resizing does not require an asynchronous state update or replace controls.
struct SettingsLabeledRow<Label: View, Control: View>: View {
  var reservesControlWidth = true
  @ViewBuilder var label: () -> Label
  @ViewBuilder var control: () -> Control

  var body: some View {
    SettingsLabeledRowLayout(reservesControlWidth: reservesControlWidth) {
      label().appFont(size: SettingsRowTypography.labelSize, weight: .medium)
      control()
    }.accessibilityElement(children: .contain)
  }
}

private struct SettingsLabeledRowLayout: Layout {
  var reservesControlWidth: Bool

  private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews)
    -> (width: CGFloat, labelWidth: CGFloat, controlProposal: ProposedViewSize, label: CGSize, control: CGSize) {
    let labelIdeal = subviews[0].sizeThatFits(.unspecified)
    let controlIdeal = subviews[1].sizeThatFits(.unspecified)
    let hasLabel = labelIdeal.width > 0 || labelIdeal.height > 0
    let gap = hasLabel ? SettingsCardLayout.rowGap : 0
    let hasControl = controlIdeal.width > 0 || controlIdeal.height > 0
    let reserves = reservesControlWidth && hasLabel && hasControl
    let ideal = labelIdeal.width + max(controlIdeal.width, reserves ? 160 : 0) + gap
    let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal)
    let minimum = reserves ? min(160, width * 0.4) : 0
    let controlWidth = min(width, max(controlIdeal.width, minimum))
    let labelWidth = max(0, width - controlWidth - gap)
    let controlProposal = ProposedViewSize(width: controlWidth, height: nil)
    return (width, labelWidth, controlProposal,
      subviews[0].sizeThatFits(.init(width: labelWidth, height: nil)),
      subviews[1].sizeThatFits(controlProposal))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let sizes = dimensions(proposal, subviews)
    return .init(width: sizes.width, height: max(sizes.label.height, sizes.control.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let sizes = dimensions(.init(width: bounds.width, height: bounds.height), subviews)
    subviews[0].place(at: .init(x: bounds.minX,
      y: bounds.midY - sizes.label.height / 2), anchor: .topLeading,
      proposal: .init(width: sizes.labelWidth, height: sizes.label.height))
    subviews[1].place(at: .init(x: bounds.maxX - sizes.control.width,
      y: bounds.midY - sizes.control.height / 2), anchor: .topLeading, proposal: sizes.controlProposal)
  }
}

private struct SettingsTextLineHeight: ViewModifier {
  let text: String
  let fontSize: CGFloat
  let lineHeight: CGFloat
  let weight: Font.Weight
  @Environment(\.appAppearance) private var appearance
  @State private var naturalHeight: CGFloat?
  func body(content: Content) -> some View {
    let extra = naturalHeight.map { lineHeight * CGFloat(appearance.uiSize) / 14 - $0 } ?? 0
    content.lineSpacing(extra).padding(.vertical, extra / 2)
      .background(alignment: .topLeading) {
        Text(text.replacingOccurrences(of: "\n", with: " "))
          .appFont(size: fontSize, weight: weight).lineLimit(1).fixedSize()
          .background {
            GeometryReader { geometry in
              Color.clear.preference(key: SettingsNaturalLineHeightKey.self, value: geometry.size.height)
            }
          }.hidden().accessibilityHidden(true).allowsHitTesting(false)
      }
      .onPreferenceChange(SettingsNaturalLineHeightKey.self) { value in
        if value != naturalHeight { naturalHeight = value }
      }
  }
}

private struct SettingsNaturalLineHeightKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

extension View {
  func settingsTextLineHeight(text: String, fontSize: CGFloat, lineHeight: CGFloat,
    weight: Font.Weight = .regular) -> some View {
    modifier(SettingsTextLineHeight(text: text, fontSize: fontSize, lineHeight: lineHeight, weight: weight))
  }
}
