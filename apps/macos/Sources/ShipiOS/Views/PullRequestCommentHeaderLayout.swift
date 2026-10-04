import SwiftUI

/// The comment header keeps its identity and accessories together until their
/// natural widths no longer fit, then wraps the accessories onto another row.
struct PullRequestCommentHeaderLayout: Layout {
  var minimumIdentityWidth: CGFloat = 52
  private let gap: CGFloat = 8
  private func sizes(_ proposal: ProposedViewSize, _ views: Subviews) -> (CGFloat, CGSize, CGSize, Bool) {
    guard views.count == 2 else { return (0, .zero, .zero, false) }
    let accessory = views[1].sizeThatFits(.unspecified)
    let naturalWidth = max(minimumIdentityWidth, views[0].sizeThatFits(.unspecified).width)
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth + gap + accessory.width
    let wraps = naturalWidth + gap + accessory.width > width
    let identity = views[0].sizeThatFits(.init(width: max(0, min(width, naturalWidth)), height: nil))
    return (width, identity, accessory, wraps)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let (width, identity, accessory, wraps) = sizes(proposal, subviews)
    return .init(width: width, height: wraps ? max(24, identity.height) + gap + accessory.height : max(24, identity.height, accessory.height))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let (_, identity, accessory, wraps) = sizes(.init(width: bounds.width, height: bounds.height), subviews)
    let firstHeight = max(24, identity.height)
    subviews[0].place(at: .init(x: bounds.minX, y: bounds.minY + (wraps ? firstHeight : bounds.height) / 2),
      anchor: .leading, proposal: .init(width: identity.width, height: identity.height))
    subviews[1].place(at: .init(x: wraps ? bounds.minX : bounds.maxX - accessory.width,
      y: wraps ? bounds.minY + firstHeight + gap + accessory.height / 2 : bounds.midY),
      anchor: .leading, proposal: .init(accessory))
  }
}
