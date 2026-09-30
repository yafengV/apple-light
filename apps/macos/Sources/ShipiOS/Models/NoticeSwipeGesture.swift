import CoreGraphics
import Foundation

/// The shipped toaster uses right-only swipes, a locked drag axis, and a
/// resistant displacement when the gesture goes against that direction.
struct NoticeSwipeGesture {
  enum Axis { case horizontal, vertical }
  private(set) var axis: Axis?
  private(set) var horizontalOffset: CGFloat = 0
  private(set) var startedAt: TimeInterval?
  private(set) var startedOnButton = false

  mutating func begin(at time: TimeInterval, onButton: Bool) {
    axis = nil; horizontalOffset = 0
    startedAt = time; startedOnButton = onButton
  }

  mutating func move(x: CGFloat, y: CGFloat, selectionActive: Bool = false) -> CGFloat {
    guard startedAt != nil, !startedOnButton, !selectionActive else { return horizontalOffset }
    // Sonner chooses the axis after the first nontrivial movement. The
    // effective displacement starts on the following pointer-move event.
    if axis == nil {
      guard abs(x) > 1 || abs(y) > 1 else { return 0 }
      axis = abs(x) > abs(y) ? .horizontal : .vertical
      return 0
    }
    guard axis == .horizontal else { return 0 }
    horizontalOffset = x >= 0 ? x : x / (1.5 + abs(x) / 20)
    return horizontalOffset
  }

  func shouldDismiss(at time: TimeInterval) -> Bool {
    guard startedAt != nil, axis == .horizontal, !startedOnButton else { return false }
    let distance = abs(horizontalOffset)
    let milliseconds = floor(time * 1_000) - floor(startedAt! * 1_000)
    let fastEnough = milliseconds == 0 ? distance > 0 : distance / milliseconds > 0.11
    return distance >= 45 || fastEnough
  }
}
