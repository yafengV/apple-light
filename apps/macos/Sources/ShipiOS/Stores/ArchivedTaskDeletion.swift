import Foundation

extension WorkspaceStore {
  func restoreArchivedTaskWithFeedback(_ taskID: String) async {
    guard !restoringArchivedTaskIDs.contains(taskID), !hasSettingsConfirmation else { return }
    restoringArchivedTaskIDs.insert(taskID)
    defer { restoringArchivedTaskIDs.remove(taskID) }
    let noticeID = "restore-" + taskID
    notices.show(id: noticeID, title: "正在恢复任务…", level: .pending)
    await Task.yield()
    if restoreArchivedTask(taskID) {
      notices.show(id: noticeID, title: "已恢复任务", level: .info, taskID: taskID)
    } else {
      notices.show(id: noticeID, title: archivedTaskDeletionError ?? "无法恢复归档任务", level: .error)
    }
  }

  func openNoticeTask(_ notice: WorkspaceNotice) async {
    guard !hasSettingsConfirmation, presentedOverlay == nil, let taskID = notice.taskID else { return }
    guard notices.items.contains(where: { $0.id == notice.id && $0.taskID == taskID && $0.level != .pending }) else { return }
    guard let task = library.tasks.first(where: { $0.id == taskID && !$0.isPopoutDraft }) else {
      notices.show(id: notice.id, title: "任务已恢复，但无法打开：任务已不存在。", level: .error)
      return
    }
    guard canSelectTask(task) else {
      notices.show(id: notice.id, title: "任务已恢复，但当前操作尚未完成，请稍后打开。", level: .error, taskID: taskID)
      return
    }
    recordNavigation()
    if currentProjectKey != task.project {
      notices.show(id: notice.id, title: "正在打开任务…", level: .pending)
      guard await openTaskScope(task.project) else {
        notices.show(id: notice.id, title: "任务已恢复，但无法打开项目。", level: .error, taskID: taskID)
        return
      }
    }
    guard let latest = library.tasks.first(where: { $0.id == taskID }) else {
      notices.show(id: notice.id, title: "任务已恢复，但无法打开：任务已不存在。", level: .error)
      return
    }
    applyTaskSelection(latest)
    notices.completeAndDismiss(notice.id)
  }

  func requestArchiveDeletion(_ kind: ArchiveDeletionRequest.Kind, ids: Set<String>) {
    guard !hasSettingsConfirmation, presentedOverlay == nil, !ids.isEmpty else { return }
    archivedTaskDeletionError = nil
    archiveDeletion = .init(kind: kind, taskIDs: ids)
  }

  func dismissArchiveDeletion() {
    guard !deletingArchive else { return }
    archiveDeletion = nil
    archivedTaskDeletionError = nil
  }

  func confirmArchiveDeletion() async {
    guard let request = archiveDeletion, !deletingArchive else { return }
    deletingArchive = true
    defer { deletingArchive = false }
    // Publish the busy state before the atomic, main-actor library commit.
    // Build the candidate after yielding so intervening library updates survive.
    await Task.yield()
    guard archiveDeletion?.id == request.id else { return }
    if deleteArchivedTasks(request.taskIDs) { archiveDeletion = nil }
  }

  func deleteArchivedTask(_ taskID: String) {
    deleteArchivedTasks([taskID])
  }

  func deleteAllArchivedTasks() {
    deleteArchivedTasks(Set(library.tasks.filter(\.archived).map(\.id)))
  }

  @discardableResult func restoreArchivedTask(_ taskID: String) -> Bool {
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID && $0.archived && !$0.isPopoutDraft }) else { return false }
    do {
      var candidate = library
      candidate.tasks[index].archived = false
      candidate.tasks[index].archivedAt = nil
      try commitLibrary(candidate)
      archivedTaskDeletionError = nil
      return true
    } catch {
      archivedTaskDeletionError = "无法恢复归档任务：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func deleteArchivedTasks(_ taskIDs: Set<String>) -> Bool {
    guard !taskIDs.isEmpty else { return true }
    do {
      var candidate = library
      let originalTaskCount = candidate.tasks.count
      let originalTaskIDs = Set(candidate.tasks.map(\.id))
      let eligible = Set(candidate.tasks.filter { taskIDs.contains($0.id) && $0.archived && !$0.isPopoutDraft }.map(\.id))
      let deletedRuns = candidate.deleteArchivedTasks(eligible)
      guard candidate.tasks.count != originalTaskCount else {
        archivedTaskDeletionError = nil
        return true
      }
      let deletedSelectionIDs = deletedRuns.union(originalTaskIDs.subtracting(candidate.tasks.map(\.id)))
      try commitLibrary(candidate)
      if selection.map(deletedSelectionIDs.contains) == true { selection = nil }
      navigationBack.removeAll { $0.run.map(deletedSelectionIDs.contains) == true }
      navigationForward.removeAll { $0.run.map(deletedSelectionIDs.contains) == true }
      archivedTaskDeletionError = nil
      return true
    } catch {
      archivedTaskDeletionError = "无法删除归档任务：\(error.localizedDescription)"
      return false
    }
  }
}
