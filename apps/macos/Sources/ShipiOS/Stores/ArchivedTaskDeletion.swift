import Foundation

extension WorkspaceStore {
  var archiveActionsBusy: Bool { deletingArchive || !restoringArchivedTaskIDs.isEmpty }
  var canMutateArchive: Bool { !archiveActionsBusy && !libraryLoading && libraryReadError == nil }

  func restoreArchivedTaskWithFeedback(_ taskID: String) async {
    guard canMutateArchive, !hasSettingsConfirmation else { return }
    restoringArchivedTaskIDs.insert(taskID)
    defer { restoringArchivedTaskIDs.remove(taskID) }
    let noticeID = "restore-" + taskID
    notices.show(id: noticeID, title: "正在恢复任务…", level: .pending)
    await Task.yield()
    guard await restoreManagedArchiveIfNeeded(taskID) else {
      notices.show(id: noticeID, title: archivedTaskDeletionError ?? "无法恢复工作树", level: .error)
      return
    }
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
    guard canMutateArchive, !hasSettingsConfirmation, presentedOverlay == nil, !ids.isEmpty else { return }
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
    do {
      let eligible = Set(library.tasks.filter {
        request.taskIDs.contains($0.id) && $0.archived && !$0.isPopoutDraft
      }.map(\.id))
      let retained = library.managedWorktrees.filter {
        eligible.contains($0.taskID) && $0.archivedPruned != true
          && FileManager.default.fileExists(atPath: $0.path)
      }
      for record in retained { try await WorktreeService.validateRetainedManaged(record) }
      if deleteArchivedTasks(request.taskIDs,
        validatedManaged: Set(retained.map(\.taskID))) {
        await managedDeletionCleanupTask?.value
        archiveDeletion = nil
      }
    } catch {
      archivedTaskDeletionError = "无法安全删除归档任务：\(error.localizedDescription)"
    }
  }

  func deleteArchivedTask(_ taskID: String) {
    deleteArchivedTasks([taskID])
  }

  func deleteAllArchivedTasks() {
    deleteArchivedTasks(Set(library.tasks.filter(\.archived).map(\.id)))
  }

  @discardableResult func restoreArchivedTask(_ taskID: String) -> Bool {
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID && $0.archived && !$0.isPopoutDraft }) else { return false }
    if let managed = library.managedWorktrees.first(where: { $0.taskID == taskID }),
      managed.archivedPruned == true || !FileManager.default.fileExists(atPath: managed.path) {
      archivedTaskDeletionError = "请先恢复此任务的托管工作树。"
      return false
    }
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

  @discardableResult func deleteArchivedTasks(_ taskIDs: Set<String>,
    validatedManaged: Set<String> = []) -> Bool {
    guard !taskIDs.isEmpty else { return true }
    do {
      var candidate = library
      let originalTaskCount = candidate.tasks.count
      let originalTaskIDs = Set(candidate.tasks.map(\.id))
      let eligible = Set(candidate.tasks.filter { taskIDs.contains($0.id) && $0.archived && !$0.isPopoutDraft }.map(\.id))
      let managed = candidate.managedWorktrees.filter { eligible.contains($0.taskID) }
      for record in managed {
        guard record.pendingHandoff == nil else {
          throw AgentFailure(message: "工作树任务仍有未完成的移交，请先恢复任务：\(record.path)")
        }
        let hasSourceSnapshot = record.sourceStashCommit != nil
          || record.sourceCopiedFiles?.isEmpty == false
        guard !hasSourceSnapshot || record.sourceChangesApplied == true else {
          throw AgentFailure(message: "工作树仍有待传递的来源修改，请先恢复任务：\(record.path)")
        }
        if record.archivedPruned != true && FileManager.default.fileExists(atPath: record.path) {
          guard validatedManaged.contains(record.taskID) else {
            throw AgentFailure(message: "请先检查仍在磁盘的托管工作树：\(record.path)")
          }
          if !candidate.permanentWorktrees.contains(where: { $0.path == record.path }) {
            let checkout = record.checkout
            let title = candidate.tasks.first(where: { $0.id == record.taskID })?.title
              ?? checkout.title
            var permanent = PermanentWorktree(id: checkout.id, source: checkout.source,
              path: checkout.path, commonDirectory: checkout.commonDirectory,
              startingCommit: checkout.startingCommit, startingName: checkout.startingName,
              createdAt: checkout.createdAt, title: title)
            permanent.ready = true
            candidate.permanentWorktrees.append(permanent)
          }
          if !candidate.projects.contains(record.path) { candidate.projects.insert(record.path, at: 0) }
          if candidate.projectNames[record.path] == nil {
            candidate.projectNames[record.path] = candidate.tasks.first(where: {
              $0.id == record.taskID
            })?.title ?? record.checkout.title
          }
        }
        candidate.newTaskExecutions[record.taskID] = nil
        candidate.pendingManagedDraftTaskIDs = candidate.pendingManagedDraftTaskIDs.filter {
          $0.value != record.taskID
        }
      }
      candidate.managedWorktrees.removeAll { eligible.contains($0.taskID) }
      let alreadyPending = Set(candidate.pendingManagedWorktreeDeletions.map(\.taskID))
      candidate.pendingManagedWorktreeDeletions.append(contentsOf: managed.filter {
        !alreadyPending.contains($0.taskID)
      })
      let deletedRuns = candidate.deleteArchivedTasks(eligible)
      guard candidate.tasks.count != originalTaskCount else {
        archivedTaskDeletionError = nil
        return true
      }
      let deletedSelectionIDs = deletedRuns.union(originalTaskIDs.subtracting(candidate.tasks.map(\.id)))
      let originalSnapshotIDs = Set(deletedRuns.map { library.forkRunOrigins[$0] ?? $0 })
      let deletedDiffIDs = Set((library.chatRuns + library.forkRuns)
        .filter { deletedRuns.contains($0.id) }.compactMap { $0.codexTurnDiff?.id })
      try commitLibrary(candidate)
      if !managed.isEmpty { scheduleManagedDeletionCleanup() }
      let retainedSnapshotIDs = Set(candidate.chatRuns.map(\.id))
        .union(candidate.forkRunOrigins.values)
      for id in originalSnapshotIDs.subtracting(retainedSnapshotIDs) {
        ReviewSnapshotStorage.remove(runID: id, root: dataRoot)
      }
      let retainedDiffIDs = Set((candidate.chatRuns + candidate.forkRuns)
        .compactMap { $0.codexTurnDiff?.id })
      for id in deletedDiffIDs.subtracting(retainedDiffIDs) {
        CodexTurnDiffStorage.remove(id: id, root: dataRoot)
      }
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
