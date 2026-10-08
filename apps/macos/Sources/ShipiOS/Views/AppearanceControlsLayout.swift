import SwiftUI

/// The public font/accent wrapper has min-width:0. Each full-width trigger retains
/// its intrinsic minimum, capped by the wrapper's available width. Measuring
/// and placing existing subviews preserves their native responder identities.
struct AppearanceControlsLayout: Layout {
  private let gap: CGFloat = 8
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let natural = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, sizes.count - 1))
    return .init(width: min(natural, proposal.width ?? natural), height: sizes.map(\.height).max() ?? 0)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    for view in subviews {
      let size = view.sizeThatFits(.init(width: bounds.width, height: nil))
      view.place(at: .init(x: x, y: bounds.midY - size.height / 2), anchor: .topLeading,
        proposal: .init(width: size.width, height: size.height))
      x += size.width + gap
    }
  }
}
