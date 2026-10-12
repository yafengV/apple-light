import AppKit
import SwiftUI

struct ReviewSplitRow<Left: View, Right: View>: View {
  var wrap: Bool
  var minimumColumnWidth: CGFloat = 0
  @ViewBuilder var left: Left
  @ViewBuilder var right: Right

  var body: some View {
    ReviewSplitRowLayout(wrap: wrap, minimumColumnWidth: minimumColumnWidth) {
      left
      Divider()
      right
    }
  }
}

enum ReviewSplitMetrics {
  @MainActor static func minimumColumnWidth(lines: [ReviewDiffLine], appearance: AppearancePreferences) -> CGFloat {
    let font = appearance.nativeFont(size: 11, code: true)
    let longest = lines.filter(\.canComment).reduce(CGFloat.zero) { width, line in
      max(width, (line.displayText(markerStyle: appearance.diffMarkerStyle) as NSString)
        .size(withAttributes: [.font: font]).width)
    }
    // Comment control, line number, code insets, and glyph rounding.
    return max(360, ceil(longest) + 22 + 38 + 12 + 10 + 4)
  }
}

/// HStack allocates more space to a long line, moving its gutter into the other
/// column. Give both cells the same proposal, including rows with a missing side.
private struct ReviewSplitRowLayout: Layout {
  let wrap: Bool
  let minimumColumnWidth: CGFloat
  private let dividerWidth: CGFloat = 1

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 3 else { return .zero }
    let ideal = max(subviews[0].sizeThatFits(.unspecified).width,
      subviews[2].sizeThatFits(.unspecified).width)
    let minimum = 2 * (minimumColumnWidth > 0 ? minimumColumnWidth : ideal) + dividerWidth
    let width = wrap ? (proposal.width ?? minimum) : max(proposal.width ?? 0, minimum)
    let column = max(0, (width - dividerWidth) / 2)
    let cellProposal = ProposedViewSize(width: column, height: nil)
    let height = max(subviews[0].sizeThatFits(cellProposal).height,
      subviews[2].sizeThatFits(cellProposal).height)
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
    cache: inout ()) {
    guard subviews.count == 3 else { return }
    let column = max(0, (bounds.width - dividerWidth) / 2)
    let cellProposal = ProposedViewSize(width: column, height: bounds.height)
    subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: cellProposal)
    subviews[1].place(at: CGPoint(x: bounds.minX + column, y: bounds.minY),
      anchor: .topLeading, proposal: ProposedViewSize(width: dividerWidth, height: bounds.height))
    subviews[2].place(at: CGPoint(x: bounds.minX + column + dividerWidth, y: bounds.minY),
      anchor: .topLeading, proposal: cellProposal)
  }
}
