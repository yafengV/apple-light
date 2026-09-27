import Foundation

enum ActivityFilter: String, CaseIterable, Identifiable {
  case all, needsAction, running, unread, pinned, scheduled
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "全部"
    case .needsAction: "待处理"
    case .running: "运行中"
    case .unread: "未读"
    case .pinned: "已置顶"
    case .scheduled: "计划任务"
    }
  }
  func includes(_ item: ActivityTaskEntry) -> Bool {
    switch self {
    case .all: true
    case .needsAction: item.attention != nil
    case .running: item.running
    case .unread: item.unread
    case .pinned: item.task.pinned
    case .scheduled: item.scheduled
    }
  }
}

struct ActivityTaskEntry: Identifiable {
  let task: WorkspaceTask
  let attention: TaskAttentionKind?
  let running: Bool
  let unread: Bool
  let scheduled: Bool
  var id: String { task.id }
  var priority: Int { attention != nil ? 0 : running ? 1 : unread ? 2 : task.pinned ? 3 : 4 }
  var statusTitle: String {
    if let attention { return attention.title }
    if running { return "正在运行" }
    if unread { return "未读活动" }
    if task.pinned { return "已置顶" }
    return "计划任务"
  }
  var statusIcon: String {
    if attention != nil { return "exclamationmark.circle.fill" }
    if running { return "progress.indicator" }
    if unread { return "circle.fill" }
    return task.pinned ? "pin.fill" : "calendar"
  }
}

extension WorkspaceStore {
  var activityEntries: [ActivityTaskEntry] {
    guard libraryLoaded else { return [] }
    let scheduledIDs = Set(automationPreferences.items.compactMap(\.taskID))
    let knownRuns = Dictionary((library.localRuns + runs).map { ($0.id, $0) },
      uniquingKeysWith: { _, last in last })
    return library.tasks.compactMap { task in
      guard !task.archived, !task.isTransient else { return nil }
      let kind = taskAttentionKind(for: task)
      let attention = kind?.requiresAction == true ? kind : nil
      let running = task.runIDs.contains { knownRuns[$0]?.isActive == true }
      let unread = library.unreadTasks.contains(task.id)
      let scheduled = scheduledIDs.contains(task.id)
        || task.runIDs.contains { knownRuns[$0]?.request["automation_id"].text != nil }
      guard attention != nil || running || unread || task.pinned || scheduled else { return nil }
      return ActivityTaskEntry(task: task, attention: attention, running: running,
        unread: unread, scheduled: scheduled)
    }.sorted {
      if $0.priority != $1.priority { return $0.priority < $1.priority }
      let left = $0.task.updatedAt ?? $0.task.createdAt ?? .distantPast
      let right = $1.task.updatedAt ?? $1.task.createdAt ?? .distantPast
      if left != right { return left > right }
      return $0.id < $1.id
    }
  }

  var activityBadgeCount: Int { activityEntries.filter { $0.attention != nil || $0.unread }.count }

  @discardableResult func openActivityTask(_ id: String) async -> Bool {
    guard let task = library.tasks.first(where: { $0.id == id }),
      !task.archived, canSelectTask(task) else { return false }
    activityError = nil
    let wasInActivity = destination == .activity
    let opened = await selectTaskAwaitingScope(task)
    if opened {
      for automation in automationPreferences.items where automation.needsReview {
        for runID in automation.unresolvedRunIDs where task.runIDs.contains(runID) {
          markAutomationReviewed(automation.id, runID: runID)
        }
      }
    } else {
      activityError = "无法打开此任务。请检查所属项目是否可用。"
      if wasInActivity { destination = .activity }
    }
    return opened
  }
}
