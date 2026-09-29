import Foundation
import Observation

struct WorkspaceNotice: Identifiable, Equatable {
  enum Level { case pending, info, success, warning, error }
  let id: String
  let generation = UUID()
  var title: String
  var description: String? = nil
  var level: Level
  var taskID: String?
  var remaining: TimeInterval?
}

@Observable final class WorkspaceNotices {
  private(set) var items: [WorkspaceNotice] = []
  var paused = false
  var visible: [WorkspaceNotice] { Array(items.prefix(3)) }

  func show(id: String, title: String, description: String? = nil, level: WorkspaceNotice.Level, taskID: String? = nil) {
    let notice = WorkspaceNotice(id: id, title: title, description: description, level: level, taskID: taskID,
      remaining: level == .pending ? nil : 5)
    // The public ID replaces an older toast; the rendered toast is a new
    // arrival at the front, with fresh actions and a fresh lifetime.
    items.removeAll { $0.id == id }; items.insert(notice, at: 0)
  }

  func dismiss(_ id: String, generation: UUID? = nil) {
    items.removeAll { $0.id == id && (generation == nil || $0.generation == generation) && $0.level != .pending }
  }

  func completeAndDismiss(_ id: String) { items.removeAll { $0.id == id } }

  func advance(by elapsed: TimeInterval) {
    guard !paused, elapsed.isFinite, elapsed > 0 else { return }
    for index in items.indices {
      if let remaining = items[index].remaining { items[index].remaining = remaining - elapsed }
    }
    items.removeAll { ($0.remaining ?? .infinity) <= 0 }
  }
}
