import Foundation

struct WorkspacePanelSizes: Codable, Equatable {
  var inspectorWidth: Double?
  var terminalHeight: Double?
  static let divider = 6.0

  static func inspectorBounds(available: Double) -> ClosedRange<Double> {
    let maximum = max(0, finite(available) - 320 - divider)
    return min(280, maximum)...maximum
  }
  static func terminalBounds(available: Double) -> ClosedRange<Double> {
    let maximum = max(0, finite(available) - 260 - divider)
    return min(140, maximum)...maximum
  }
  func inspector(available: Double) -> Double {
    Self.clamp(
      inspectorWidth ?? min(480, Self.finite(available) * 0.5),
      to: Self.inspectorBounds(available: available))
  }
  func terminal(available: Double) -> Double {
    Self.clamp(terminalHeight ?? 235, to: Self.terminalBounds(available: available))
  }
  static func clamp(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
    min(bounds.upperBound, max(bounds.lowerBound, finite(value)))
  }
  private static func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}
