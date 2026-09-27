import Foundation

enum ActivityFilter: String, CaseIterable, Identifiable {
  case all, needsAction, running, unread
  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: "全部"
    case .needsAction: "待处理"
    case .running: "运行中"
    case .unread: "未读"
    }
  }
  func includes(_ item: ActivityTaskEntry) -> Bool {
    switch self {
    case .all: true
    case .needsAction: item.attention != nil
    case .running: item.running
    case .unread: item.unread
    }
  }
}

struct ActivityTaskEntry: Identifiable {
  let task: WorkspaceTask
  let attention: TaskAttentionKind?
  let running: Bool
  let unread: Bool
  var id: String { task.id }
  var priority: Int { attention != nil ? 0 : running ? 1 : 2 }
  var statusTitle: String {
    if let attention { return attention.title }
    return running ? "正在运行" : "未读活动"
  }
  var statusIcon: String {
    if attention != nil { return "exclamationmark.circle.fill" }
    return running ? "progress.indicator" : "circle.fill"
  }
}

extension WorkspaceStore {
  var activityEntries: [ActivityTaskEntry] {
    guard libraryLoaded else { return [] }
    return library.tasks.compactMap { task in
      guard !task.archived, !task.isPopoutDraft else { return nil }
      let kind = taskAttentionKind(for: task)
      let attention = kind?.requiresAction == true ? kind : nil
      let running = activeRun(taskID: task.id) != nil
      let unread = library.unreadTasks.contains(task.id)
      guard attention != nil || running || unread else { return nil }
      return ActivityTaskEntry(task: task, attention: attention, running: running, unread: unread)
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
    if !opened {
      activityError = "无法打开此任务。请检查所属项目是否可用。"
      if wasInActivity { destination = .activity }
    }
    return opened
  }
}
