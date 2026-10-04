import Foundation

/// Public TableScroller animation-range plus edge-fade-horizontal keyframes.
struct PRCommentTableEdgeFade: Equatable {
  let width: CGFloat
  let left: CGFloat
  let right: CGFloat

  init?(viewport: CGFloat, document: CGFloat, offset: CGFloat, distance: CGFloat = 16) {
    guard viewport.isFinite, document.isFinite, offset.isFinite, distance.isFinite,
      viewport > 0, document > viewport, distance >= 0 else { return nil }
    width = viewport
    let range = document - viewport
    let start = min(2, range * 0.5), end = max(range - 2, range * 0.5)
    let progress: CGFloat
    if end == start { progress = offset < start ? 0 : 1 }
    else { progress = min(1, max(0, (offset - start) / (end - start))) }
    left = distance * min(1, progress / 0.001)
    right = distance * min(1, (1 - progress) / 0.001)
  }
  /// CSS fixes decreasing gradient stops before clipping them to the viewport.
  /// This matters below 32 points: clamping the fade lengths first changes the ramp.
  var stops: [(position: CGFloat, alpha: CGFloat)] {
    let solidEnd = max(left, width - right), end = max(solidEnd, width)
    let positions = Set([CGFloat(0), width, min(width, left), min(width, solidEnd)]).sorted()
    return positions.map { x in
      let alpha: CGFloat
      if x < left { alpha = left > 0 ? x / left : 1 }
      else if x <= solidEnd { alpha = 1 }
      else { alpha = end > solidEnd ? (end - x) / (end - solidEnd) : 1 }
      return (x / width, min(1, max(0, alpha)))
    }
  }
}
