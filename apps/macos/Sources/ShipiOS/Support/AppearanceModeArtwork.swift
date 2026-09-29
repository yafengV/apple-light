import AppKit

/// Neutral miniature sheets from the reference's 170×120 geometric previews.
/// Drawing stays independent of custom palettes, as in the reference cards.
enum AppearanceModeArtwork {
  static func draw(_ mode: AppearanceMode, in rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform(); transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 170, yBy: rect.height / 120); transform.concat()
    if mode == .system {
      fill(0, 0, 85, 120, "#9f9f9f"); fill(85, 0, 85, 120, "#5d5d5d")
      NSGraphicsContext.saveGraphicsState(); sheet(7, 34, 156, 86, radius: 8).addClip()
      fill(7, 34, 78, 86, "#f3f3f3"); fill(85, 34, 78, 86, "#393939")
      rounded(70, 59, 27, 6, 3, "#cdcdcd")
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: .init(x: 70, y: 59, width: 27, height: 6), xRadius: 3, yRadius: 3).addClip()
      fill(85, 59, 12, 6, "#767676"); NSGraphicsContext.restoreGraphicsState()
      fill(53, 68, 32, 3, "#dfdfdf"); fill(85, 68, 32, 3, "#8f8f8f")
      NSGraphicsContext.saveGraphicsState(); sheet(26, 77, 118, 43, radius: 7).addClip()
      fill(26, 77, 59, 43, "#fff"); fill(85, 77, 59, 43, "#4f4f4f")
      for y in [85.0, 111.0] {
        rounded(32, y, 35, 6, 3, "#dfdfdf"); rounded(103, y, 35, 6, 3, "#767676")
      }
      fill(32, 96, 53, 2, "#f3f3f3"); fill(85, 96, 53, 2, "#767676")
      fill(26, 105, 59, 1, "#f3f3f3"); fill(85, 105, 59, 1, "#767676")
      NSGraphicsContext.restoreGraphicsState(); NSGraphicsContext.restoreGraphicsState()
    } else {
      fill(0, 0, 170, 120, mode == .dark ? "#5d5d5d" : "#f3f3f3")
      rounded(46, 26, 78, 6, 3, mode == .dark ? "#9f9f9f" : "#cdcdcd")
      rounded(26, 35, 118, 4, 2, mode == .dark ? "#8f8f8f" : "#dfdfdf")
      NSColor.white.setFill(); sheet(15, 44, 140, 76, radius: 8).fill()
      for y in [56.0, 80.0, 104.0] {
        rounded(22, y, 45, 6, 3, "#dfdfdf"); fill(22, y + 11, 65, 2, "#f3f3f3")
      }
      fill(15, 76, 140, 1, "#f3f3f3"); fill(15, 100, 140, 1, "#f3f3f3")
    }
    NSGraphicsContext.restoreGraphicsState()
  }
  private static func sheet(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: .init(x: x, y: y + h)); p.line(to: .init(x: x, y: y + radius))
    p.curve(to: .init(x: x + radius, y: y), controlPoint1: .init(x: x, y: y + radius * 0.447715), controlPoint2: .init(x: x + radius * 0.447715, y: y))
    p.line(to: .init(x: x + w - radius, y: y))
    p.curve(to: .init(x: x + w, y: y + radius), controlPoint1: .init(x: x + w - radius * 0.447715, y: y), controlPoint2: .init(x: x + w, y: y + radius * 0.447715))
    p.line(to: .init(x: x + w, y: y + h)); p.close(); return p
  }
  private static func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: String) {
    let color = hex == "#fff" ? NSColor.white : AppearanceRGBA(hex: hex).nativeColor
    color.setFill(); NSRect(x: x, y: y, width: w, height: h).fill()
  }
  private static func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ hex: String) {
    AppearanceRGBA(hex: hex).nativeColor.setFill(); NSBezierPath(roundedRect: .init(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r).fill()
  }
}
