import Foundation

struct TaskSearchGroup: Identifiable {
  let id: String
  let title: String
  let results: [TaskSearchResult]
}

enum TaskSearchPresentation {
  static let limit = 9

  static func groups(_ results: [TaskSearchResult], query: String, pinnedOrder: [String] = []) -> [TaskSearchGroup] {
    var seen = Set<String>()
    let unique = results.filter { seen.insert($0.id).inserted }
    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return unique.isEmpty ? [] : [.init(id: "results", title: "任务", results: Array(unique.prefix(limit)))]
    }
    let pinned = Array(unique.enumerated().filter { $0.element.task.pinned }.sorted {
      let left = pinnedOrder.firstIndex(of: $0.element.id) ?? Int.max
      let right = pinnedOrder.firstIndex(of: $1.element.id) ?? Int.max
      return left == right ? $0.offset < $1.offset : left < right
    }.map(\.element).prefix(limit))
    let recent = unique.enumerated().filter { !$0.element.task.pinned }.sorted {
      let left = $0.element.task.updatedAt ?? $0.element.task.createdAt ?? .distantPast
      let right = $1.element.task.updatedAt ?? $1.element.task.createdAt ?? .distantPast
      return left == right ? $0.offset < $1.offset : left > right
    }.map(\.element)
    return [TaskSearchGroup(id: "pinned", title: "已置顶", results: pinned),
      TaskSearchGroup(id: "recent", title: "最近任务", results: Array(recent.prefix(limit - pinned.count)))]
      .filter { !$0.results.isEmpty }
  }

  static func shortcutCommand(_ index: Int) -> String? {
    (0..<limit).contains(index) ? "focus-chat-\(index + 1)" : nil
  }

  @MainActor static func shortcutSlot(_ binding: ShortcutBinding, preferences: ShortcutPreferences) -> Int? {
    (0..<limit).first { preferences.matches(shortcutCommand($0)!, binding) }
  }
}
