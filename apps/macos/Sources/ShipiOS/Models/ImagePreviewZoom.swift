import Foundation

struct ImagePreviewZoom: Equatable {
  static let steps: [Double] = [25, 33, 50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300, 400, 500]
  var naturalSize: CGSize
  var viewport: CGSize
  var requestedPercent: Double?

  var fitPercent: Double {
    guard naturalSize.width > 0, naturalSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 100 }
    return min(1, viewport.width / naturalSize.width, viewport.height / naturalSize.height) * 100
  }
  var ramp: [Double] { Array(Set(Self.steps + [fitPercent])).sorted() }
  var minimum: Double { min(25, fitPercent) }
  var percent: Double { requestedPercent.map(clamp) ?? fitPercent }
  var imageSize: CGSize { CGSize(width: naturalSize.width * percent / 100, height: naturalSize.height * percent / 100) }
  var documentSize: CGSize { CGSize(width: max(viewport.width, imageSize.width), height: max(viewport.height, imageSize.height)) }
  var imageRect: CGRect {
    CGRect(x: (documentSize.width - imageSize.width) / 2,
      y: (documentSize.height - imageSize.height) / 2, width: imageSize.width, height: imageSize.height)
  }
  func clamp(_ percent: Double) -> Double { percent.isFinite ? min(500, max(minimum, percent)) : fitPercent }
  func step(_ direction: Int) -> Double {
    direction > 0 ? (ramp.first { $0 > percent + 0.001 } ?? 500)
      : (ramp.last { $0 < percent - 0.001 } ?? minimum)
  }
  func clampedOffset(_ point: CGPoint) -> CGPoint {
    CGPoint(x: max(0, min(documentSize.width - viewport.width, point.x)),
      y: max(0, min(documentSize.height - viewport.height, point.y)))
  }
  /// Retain the image point under the cursor (or viewport center) when zooming.
  func offset(from old: Self, oldOffset: CGPoint, anchor: CGPoint) -> CGPoint {
    let oldRect = old.imageRect
    let x = oldRect.width > 0 ? (oldOffset.x + anchor.x - oldRect.minX) / oldRect.width : 0.5
    let y = oldRect.height > 0 ? (oldOffset.y + anchor.y - oldRect.minY) / oldRect.height : 0.5
    return clampedOffset(CGPoint(x: imageRect.minX + min(1, max(0, x)) * imageRect.width - anchor.x,
      y: imageRect.minY + min(1, max(0, y)) * imageRect.height - anchor.y))
  }
}
