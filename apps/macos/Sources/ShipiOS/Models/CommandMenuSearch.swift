import Foundation

/// Local counterparts of the desktop root menu's search thresholds and limits.
enum CommandMenuSearch {
  static func searchesTasks(_ query: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= 2 }
  static func searchesContent(_ query: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count >= 3 }

  static func recent(library: WorkspaceLibrary, currentID: String?) -> [TaskSearchResult] {
    let eligible = library.tasks.filter { !$0.archived && !$0.isPopoutDraft && $0.id != currentID }
    let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let chronological = eligible.enumerated().sorted {
      let left = $0.element.updatedAt ?? $0.element.createdAt ?? .distantPast
      let right = $1.element.updatedAt ?? $1.element.createdAt ?? .distantPast
      return left == right ? $0.offset < $1.offset : left > right
    }.map(\.element.id)
    let unread = chronological.filter { library.unreadTasks.contains($0) }
    var seen = Set<String>()
    return (unread + library.recentTaskIDs + chronological).compactMap { id in
      guard let task = byID[id], seen.insert(id).inserted else { return nil }
      return TaskSearchResult(task: task, projectTitle: task.project.isEmpty ? "无项目" : library.projectTitle(task.project), source: nil, snippet: nil)
    }.prefix(7).map { $0 }
  }
}

extension WorkspaceLibrary {
  @discardableResult mutating func recordTaskVisit(_ id: String) -> Bool {
    guard tasks.contains(where: { $0.id == id && !$0.isPopoutDraft }) else { return false }
    let valid = Set(tasks.filter { !$0.isPopoutDraft }.map(\.id))
    var seen: Set<String> = [id]
    let next = [id] + recentTaskIDs.filter { valid.contains($0) && seen.insert($0).inserted }
    guard next != recentTaskIDs else { return false }
    recentTaskIDs = next
    return true
  }
}
