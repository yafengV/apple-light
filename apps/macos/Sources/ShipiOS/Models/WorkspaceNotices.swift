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
  var watchAutomationID: UUID? = nil
  var watchTaskID: String? = nil
  var actionTitle: String { watchAutomationID == nil ? "查看" : "查看进度" }
  var remaining: TimeInterval?
}

@Observable final class WorkspaceNotices {
  private(set) var items: [WorkspaceNotice] = []
  @ObservationIgnored private var pauseState = false
  @ObservationIgnored private var lifetimeAnchors: [UUID: TimeInterval] = [:]
  var paused: Bool {
    get { pauseState }
    set { pauseState = newValue }
  }
  var visible: [WorkspaceNotice] { Array(items.prefix(3)) }

  func show(id: String, title: String, description: String? = nil, level: WorkspaceNotice.Level,
    taskID: String? = nil, watchAutomationID: UUID? = nil, watchTaskID: String? = nil,
    at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    let notice = WorkspaceNotice(id: id, title: title, description: description, level: level, taskID: taskID,
      watchAutomationID: watchAutomationID, watchTaskID: watchTaskID,
      remaining: level == .pending ? nil : 5)
    // The public ID replaces an older toast; the rendered toast is a new
    // arrival at the front, with fresh actions and a fresh lifetime.
    items.removeAll { $0.id == id }; items.insert(notice, at: 0)
    lifetimeAnchors = lifetimeAnchors.filter { key, _ in items.contains { $0.generation == key } }
    lifetimeAnchors[notice.generation] = uptime
  }

  func dismiss(_ id: String, generation: UUID? = nil) {
    items.removeAll { $0.id == id && (generation == nil || $0.generation == generation) && $0.level != .pending }
    pruneLifetimeAnchors()
  }

  func completeAndDismiss(_ id: String) { items.removeAll { $0.id == id }; pruneLifetimeAnchors() }

  /// Account for the visible interval before changing pause state. Every toast
  /// has its own birth anchor so a newly inserted toast gets a full lifetime.
  func setPaused(_ value: Bool, at uptime: TimeInterval) {
    advance(to: uptime)
    pauseState = value
  }

  func advance(to uptime: TimeInterval) {
    guard uptime.isFinite else { return }
    for index in items.indices {
      let key = items[index].generation
      let previous = lifetimeAnchors[key] ?? uptime
      guard uptime > previous else { continue }
      if !pauseState, let remaining = items[index].remaining {
        items[index].remaining = remaining - (uptime - previous)
      }
      lifetimeAnchors[key] = uptime
    }
    items.removeAll { ($0.remaining ?? .infinity) <= 0 }
    pruneLifetimeAnchors()
  }

  private func pruneLifetimeAnchors() {
    let live = Set(items.map(\.generation))
    lifetimeAnchors = lifetimeAnchors.filter { live.contains($0.key) }
  }

  func advance(by elapsed: TimeInterval) {
    guard !paused, elapsed.isFinite, elapsed > 0 else { return }
    for index in items.indices {
      if let remaining = items[index].remaining { items[index].remaining = remaining - elapsed }
    }
    items.removeAll { ($0.remaining ?? .infinity) <= 0 }
    pruneLifetimeAnchors()
  }
}
