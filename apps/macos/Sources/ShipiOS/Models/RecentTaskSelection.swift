import Foundation

/// A held shortcut freezes the visit order until a release commits selection.
struct RecentTaskSelection: Codable, Equatable {
  let threadKeys: [String]
  let selectedIndex: Int
  var selectedID: String? {
    threadKeys.indices.contains(selectedIndex) ? threadKeys[selectedIndex] : nil
  }

  static func recordingVisit(_ id: String, in recent: [String]) -> [String] {
    Array(([id] + recent.filter { $0 != id }).prefix(20))
  }

  static func step(current: String?, direction: Int, recent: [String],
    session: Self?, isAvailable: (String) -> Bool = { _ in true }) -> Self {
    let available = recent.filter(isAvailable)
    let keys = session?.threadKeys ?? current.map { recordingVisit($0, in: available) } ?? available
    if session == nil, current == nil {
      return Self(threadKeys: keys, selectedIndex: keys.isEmpty || direction > 0 ? 0 : keys.count - 1)
    }
    let index = session?.selectedIndex ?? 0
    return Self(threadKeys: keys, selectedIndex: keys.isEmpty ? 0 : (index + direction + keys.count) % keys.count)
  }
}

enum TaskNavigationOrder {
  static func adjacent(current: String?, direction: Int, targets: [String]) -> String? {
    guard !targets.isEmpty else { return nil }
    guard let current else { return direction > 0 ? targets.first : targets.last }
    guard let index = targets.firstIndex(of: current), targets.indices.contains(index + direction) else { return nil }
    return targets[index + direction]
  }
}
