import Foundation

/// Each scene owns its history; the scene route remains the current location.
struct TaskWindowNavigation {
  private(set) var back: [String] = []
  private(set) var forward: [String] = []

  func destination(backwards: Bool, current: String, available: Set<String>) -> String? {
    (backwards ? back : forward).last { $0 != current && available.contains($0) }
  }

  @discardableResult mutating func visit(_ next: String, from current: String, available: Set<String>) -> Bool {
    guard next != current, available.contains(next) else { return false }
    if available.contains(current), back.last != current { back.append(current) }
    forward.removeAll()
    return true
  }

  mutating func move(backwards: Bool, current: String, available: Set<String>) -> String? {
    var source = backwards ? back : forward
    while let next = source.popLast() {
      guard next != current, available.contains(next) else { continue }
      if backwards {
        back = source
        if available.contains(current), forward.last != current { forward.append(current) }
      } else {
        forward = source
        if available.contains(current), back.last != current { back.append(current) }
      }
      return next
    }
    if backwards { back.removeAll() } else { forward.removeAll() }
    return nil
  }
}
