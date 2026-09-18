import Foundation

enum SettingsSearchHighlight {
  static let duration: TimeInterval = 0.45

  /// Matches the reference's 450 ms [opaque, opaque at .35, clear] keyframes
  /// with cubic-bezier(.23, 1, .32, 1). Reduced motion keeps a brief solid cue.
  static func opacity(elapsed: TimeInterval, reducedMotion: Bool) -> Double {
    guard elapsed >= 0, elapsed < duration else { return 0 }
    if reducedMotion { return 1 }
    let progress = elapsed / duration
    var low = 0.0, high = 1.0
    for _ in 0..<24 {
      let t = (low + high) / 2, inverse = 1 - t
      let x = 3 * inverse * inverse * t * 0.23 + 3 * inverse * t * t * 0.32 + t * t * t
      if x < progress { low = t } else { high = t }
    }
    let t = (low + high) / 2
    let eased = 1 - pow(1 - t, 3)
    return eased <= 0.35 ? 1 : max(0, (1 - eased) / 0.65)
  }
}
