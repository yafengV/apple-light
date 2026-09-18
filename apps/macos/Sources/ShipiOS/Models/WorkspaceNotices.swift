import Foundation
import Observation

struct WorkspaceNotice: Identifiable, Equatable {
  enum Level { case pending, info, success, error }
  let id: String
  var title: String
  var level: Level
  var taskID: String?
  var remaining: TimeInterval?
}

@Observable final class WorkspaceNotices {
  private(set) var items: [WorkspaceNotice] = []
  var paused = false
  var visible: [WorkspaceNotice] { Array(items.prefix(3)) }

  func show(id: String, title: String, level: WorkspaceNotice.Level, taskID: String? = nil) {
    let notice = WorkspaceNotice(id: id, title: title, level: level, taskID: taskID,
      remaining: level == .pending ? nil : 5)
    if let index = items.firstIndex(where: { $0.id == id }) { items[index] = notice }
    else { items.insert(notice, at: 0) }
  }

  func dismiss(_ id: String) {
    items.removeAll { $0.id == id && $0.level != .pending }
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
