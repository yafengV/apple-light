import Foundation

struct ActivityTaskEntry: Identifiable {
  let task: WorkspaceTask
  let attention: TaskAttentionKind?
  let running: Bool
  let unread: Bool
  let scheduled: Bool
  var id: String { task.id }
  var needsAttention: Bool { attention != nil || running || unread }
  var recency: Date { task.updatedAt ?? task.createdAt ?? .distantPast }
  var priority: Int { attention != nil ? 0 : running ? 1 : unread ? 2 : task.pinned ? 3 : 4 }
  var statusTitle: String {
    if let attention { return attention.title }
    if running { return "正在运行" }
    if unread { return "未读活动" }
    if task.pinned { return "已置顶" }
    return scheduled ? "计划任务" : "已读"
  }
  var statusIcon: String {
    if attention != nil { return "exclamationmark.circle.fill" }
    if running { return "progress.indicator" }
    if unread { return "circle.fill" }
    return task.pinned ? "pin.fill" : scheduled ? "calendar" : "text.bubble"
  }
}

extension WorkspaceStore {
  var activityEntries: [ActivityTaskEntry] {
    guard libraryLoaded else { return [] }
    let scheduledIDs = Set(automationPreferences.items.compactMap(\.taskID))
    let knownRuns = Dictionary((library.localRuns + runs).map { ($0.id, $0) },
      uniquingKeysWith: { _, last in last })
    return library.tasks.compactMap { task in
      guard !task.archived, !task.isTransient, !task.runIDs.isEmpty else { return nil }
      let kind = taskAttentionKind(for: task)
      let attention = kind?.requiresAction == true ? kind : nil
      let running = task.runIDs.contains { knownRuns[$0]?.isActive == true } || !activeSubagents(taskID: task.id).isEmpty
      let unread = library.unreadTasks.contains(task.id)
      let scheduled = scheduledIDs.contains(task.id)
        || task.runIDs.contains { knownRuns[$0]?.request["automation_id"].text != nil }
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

  /// The nine sidebar slots address priority only while that section is shown.
  /// Recent-chat commands have their own MRU targets and do not use these slots.
  var activityNumberedTasks: [WorkspaceTask] {
    guard showingActivity else { return [] }
    let entries = library.activityPreferences.showPriority
      ? activityPriorityEntries : activitySections().flatMap(\.items)
    return entries.prefix(9).map(\.task)
  }

  func openActivityNumberedTask(_ id: String, sessionID: UUID) async {
    guard activitySession?.id == sessionID, destination != .settings,
      !shuttingDown, !restoringLibrary, shortcutCaptureCount == 0,
      renameTaskID == nil, !showingModelPicker, !showingBranchPicker,
      presentedOverlay == nil, !hasSettingsConfirmation,
      activityNumberedTasks.contains(where: { $0.id == id }) else { return }
    _ = await openActivityTask(id)
  }

  func synchronizeActivityPriority() {
    guard libraryLoaded, var session = activitySession else { return }
    let entries = activityEntries
    let existing = Set(entries.map(\.id))
    session.priorityIDs.removeAll { !existing.contains($0) }
    var retained = Set(session.priorityIDs)
    for entry in entries where entry.needsAttention && retained.insert(entry.id).inserted {
      session.priorityIDs.append(entry.id)
    }
    session.recentDates = session.recentDates.filter { existing.contains($0.key) }
    for entry in entries where !retained.contains(entry.id) && session.recentDates[entry.id] == nil {
      session.recentDates[entry.id] = entry.recency
    }
    if activitySession != session { activitySession = session }
  }

  var activityPriorityEntries: [ActivityTaskEntry] {
    guard let session = activitySession, library.activityPreferences.showPriority else { return [] }
    let options = library.activityPreferences
    let entries = Dictionary(activityEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return session.priorityIDs.compactMap { entries[$0] }.filter {
      (options.showScheduled || !$0.scheduled) && (!options.showPinned || !$0.task.pinned)
    }
  }

  func activitySections(calendar: Calendar = .current) -> [ActivitySection] {
    guard let session = activitySession else { return [] }
    let options = library.activityPreferences
    let all = activityEntries.filter { options.showScheduled || !$0.scheduled }
    let priority = activityPriorityEntries
    let pinned = options.showPinned ? all.filter(\.task.pinned) : []
    let separatedIDs = Set((priority + pinned).map(\.id))
    let start = calendar.startOfDay(for: session.activatedAt)
    let cutoff = calendar.date(byAdding: .day, value: -6, to: start) ?? start
    let dates = session.recentDates
    let recent = all.filter {
      !separatedIDs.contains($0.id) && (dates[$0.id] ?? $0.recency) >= cutoff
    }.sorted {
      let left = dates[$0.id] ?? $0.recency, right = dates[$1.id] ?? $1.recency
      return left == right ? $0.id < $1.id : left > right
    }
    var sections: [ActivitySection] = []
    if options.showPriority {
      sections.append(.init(id: .priority, title: "优先处理", items: priority))
    }
    if !pinned.isEmpty { sections.append(.init(id: .pinned, title: "已置顶", items: pinned)) }
    let days = Dictionary(grouping: recent) { calendar.startOfDay(for: dates[$0.id] ?? $0.recency) }
    let today = calendar.startOfDay(for: Date())
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
    for day in days.keys.sorted(by: >) {
      let title = day == today ? "今天" : day == yesterday ? "昨天"
        : day.formatted(.dateTime.weekday(.wide))
      sections.append(.init(id: .day(day), title: title, items: days[day] ?? []))
    }
    return sections
  }

  func setActivityOption(_ key: WritableKeyPath<ActivityPreferences, Bool>, to value: Bool) {
    var candidate = library
    candidate.activityPreferences[keyPath: key] = value
    saveActivityLibrary(candidate)
  }

  func restoreActivityDefaults() {
    var candidate = library
    candidate.activityPreferences = .init()
    saveActivityLibrary(candidate)
  }

  func clearReadActivity() {
    guard var session = activitySession else { return }
    let entries = activityEntries
    let retained = Set(entries.filter(\.needsAttention).map(\.id))
    let removed = Set(session.priorityIDs).subtracting(retained)
    for entry in entries where removed.contains(entry.id) && session.recentDates[entry.id] == nil {
      session.recentDates[entry.id] = entry.recency
    }
    session.priorityIDs.removeAll { !retained.contains($0) }
    activitySession = session
  }

  func markActivityRead() {
    let ids = Set(activityPriorityEntries.filter(\.unread).map(\.id))
    guard !ids.isEmpty else { return }
    var candidate = library
    candidate.unreadTasks.subtract(ids)
    guard saveActivityLibrary(candidate) else { return }
    for item in activityPriorityEntries where ids.contains(item.id) && item.scheduled {
      reviewActivityAutomation(item.task)
    }
  }

  @discardableResult private func saveActivityLibrary(_ candidate: WorkspaceLibrary) -> Bool {
    do { try commitLibrary(candidate); activityError = nil; return true }
    catch { activityError = error.localizedDescription; return false }
  }

  func reviewActivityAutomation(_ task: WorkspaceTask) {
    for automation in automationPreferences.items where automation.needsReview {
      for runID in automation.unresolvedRunIDs where task.runIDs.contains(runID) {
        markAutomationReviewed(automation.id, runID: runID)
      }
    }
  }

  @discardableResult func openActivityTask(_ id: String) async -> Bool {
    guard activityOpeningTaskID == nil,
      let task = library.tasks.first(where: { $0.id == id }),
      !task.archived, canSelectTask(task) else { return false }
    activityOpeningTaskID = id
    defer { activityOpeningTaskID = nil }
    activityError = nil
    let origin = destination
    let sessionID = activitySession?.id
    let opened = await selectTaskAwaitingScope(task)
    if opened {
      reviewActivityAutomation(task)
    } else if activitySession?.id == sessionID {
      activityError = "无法打开此任务。请检查所属项目是否可用。"
      destination = origin
    }
    return opened
  }
}
