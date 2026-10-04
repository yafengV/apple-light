import SwiftUI

/// The shipped Electron stylesheet scales md/lg radii by 1.25 and uses
/// superellipse(1.5). CSS defines its exponent as 2^K, not K itself.
struct PRCommentMediaCornerShape: Shape {
  var radius: CGFloat
  func path(in rect: CGRect) -> Path {
    Path(cgPath(in: rect))
  }
  /// Avoid Path().cgPath: SwiftUI bridges an empty path through CGRect.null,
  /// producing infinite coordinates rather than an empty Core Graphics path.
  func cgPath(in rect: CGRect) -> CGPath {
    let result = CGMutablePath()
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
      rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return result }
    let r = min(radius.isFinite ? max(0, radius) : 0, rect.width / 2, rect.height / 2)
    guard r > 0 else { result.addRect(rect); return result }
    let power = 2 / pow(2, 1.5)
    result.move(to: .init(x: rect.minX + r, y: rect.minY))
    let centers = [CGPoint(x: rect.maxX - r, y: rect.minY + r), .init(x: rect.maxX - r, y: rect.maxY - r),
      .init(x: rect.minX + r, y: rect.maxY - r), .init(x: rect.minX + r, y: rect.minY + r)]
    for (corner, center) in centers.enumerated() {
      for step in 0...64 {
        let angle = -.pi / 2 + Double(corner) * .pi / 2 + Double(step) * .pi / 128
        let c = cos(angle), s = sin(angle)
        result.addLine(to: .init(x: center.x + r * CGFloat((c < 0 ? -1 : 1) * pow(abs(c), power)),
          y: center.y + r * CGFloat((s < 0 ? -1 : 1) * pow(abs(s), power))))
      }
    }
    result.closeSubpath(); return result
  }
}
