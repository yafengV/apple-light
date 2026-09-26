import Foundation

enum TaskAttentionKind: Equatable {
  case approval, question, elicitation, unread

  var requiresAction: Bool { self != .unread }
  var title: String {
    switch self {
    case .approval: "等待工具批准"
    case .question: "等待回答问题"
    case .elicitation: "等待完成 MCP 请求"
    case .unread: "未读活动"
    }
  }
}

extension WorkspaceStore {
  var attentionTasks: [WorkspaceTask] {
    guard libraryLoaded else { return [] }
    return library.tasks.filter {
      !$0.archived && !$0.runIDs.isEmpty && taskAttentionKind(for: $0) != nil
    }
  }

  func taskAttentionKind(for task: WorkspaceTask) -> TaskAttentionKind? {
    guard !task.archived, !task.runIDs.isEmpty else { return nil }
    let runIDs = Set(task.runIDs)
    if mcpPendingApprovals.values.contains(where: { runIDs.contains($0.runID) }) {
      return .approval
    }
    if codexPendingQuestions.values.contains(where: { runIDs.contains($0.runID) }) {
      return .question
    }
    if codexPendingElicitations.values.contains(where: { runIDs.contains($0.runID) }) {
      return .elicitation
    }
    return library.unreadTasks.contains(task.id) ? .unread : nil
  }

  var nextAttentionTask: WorkspaceTask? {
    guard libraryLoaded, !restoringLibrary, !busy else { return nil }
    let tasks = library.tasks
    guard !tasks.isEmpty else { return nil }
    let start = tasks.firstIndex(where: { $0.id == selectedTask?.id }).map { ($0 + 1) % tasks.count } ?? 0
    return (0..<tasks.count).lazy.map { tasks[(start + $0) % tasks.count] }.first {
      taskAttentionKind(for: $0) != nil && canSelectTask($0)
    }
  }

  @discardableResult func openNextAttentionTask() async -> Bool {
    guard let target = nextAttentionTask else { return false }
    // Open the scope before consuming unread state; a missing project remains actionable.
    recordNavigation()
    guard await openTaskScope(target.project),
      let current = library.tasks.first(where: { $0.id == target.id }),
      taskAttentionKind(for: current) != nil, canSelectTask(current)
    else { return false }
    presentedOverlay = nil
    showingBranchPicker = false
    showingModelPicker = false
    showingFind = false
    applyTaskSelection(current)
    await loadDetails()
    return true
  }

  func setTaskUnread(_ id: String, unread: Bool) {
    guard libraryLoaded, library.tasks.contains(where: { $0.id == id }) else { return }
    do {
      var candidate = library
      if unread { candidate.unreadTasks.insert(id) } else { candidate.unreadTasks.remove(id) }
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }

  func clearUnreadTasks() {
    guard libraryLoaded, !library.unreadTasks.isEmpty else { return }
    do {
      var candidate = library
      candidate.unreadTasks = []
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }
}
