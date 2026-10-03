import Foundation

extension WorkspaceStore {
  var archiveActionsBusy: Bool { archivingActivity || deletingArchive || !restoringArchivedTaskIDs.isEmpty }
  var canMutateArchive: Bool { !archiveActionsBusy && !managedTaskPreparing
    && !libraryLoading && libraryReadError == nil }

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
    guard notices.items.contains(where: { $0.id == notice.id && $0.generation == notice.generation && $0.taskID == taskID && $0.level != .pending }) else { return }
    if let id = notice.watchAutomationID {
      guard let target = notice.watchTaskID,
        let watch = pullRequestWatchContent(.pullRequestWatch(id, task: target, owner: taskID)) else {
        notices.show(id: notice.id, title: "监控进度已不可用。", level: .error)
        return
      }
      if await openPullRequestWatchProgress(watch, owner: taskID, valid: {
        self.notices.items.contains { $0.generation == notice.generation && $0.id == notice.id }
      }) {
        notices.dismiss(notice.id, generation: notice.generation)
      }
      return
    }
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
      guard let opening = notices.items.first(where: { $0.id == notice.id }) else { return }
      let opened = await openTaskScope(task.project)
      guard notices.items.contains(where: { $0.id == notice.id && $0.generation == opening.generation }) else { return }
      guard opened else {
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
    if kind == .task {
      if ids.count == 1, let id = ids.first { requestTaskDeletion(id) }
      return
    }
    guard canMutateArchive, !hasSettingsConfirmation, presentedOverlay == nil, !ids.isEmpty else { return }
    archivedTaskDeletionError = nil
    archiveDeletion = .init(kind: kind, taskIDs: ids)
  }

  func dismissArchiveDeletion(requestID: UUID? = nil) {
    guard !deletingArchive, requestID == nil || archiveDeletion?.id == requestID else { return }
    archiveDeletion = nil
    archivedTaskDeletionError = nil
  }

  func confirmArchiveDeletion(requestID: UUID? = nil) async {
    guard let request = archiveDeletion, !archiveActionsBusy,
      requestID == nil || request.id == requestID else { return }
    deletingArchive = true
    if request.kind == .task { activityArchivingTaskIDs.formUnion(request.taskIDs) }
    defer {
      deletingArchive = false
      if request.kind == .task { activityArchivingTaskIDs.subtract(request.taskIDs) }
    }
    // Publish the busy state before the atomic, main-actor library commit.
    // Build the candidate after yielding so intervening library updates survive.
    await Task.yield()
    guard archiveDeletion?.id == request.id else { return }
    if request.kind == .task {
      await performTaskDeletion(request)
      return
    }
    do {
      let eligible = Set(library.tasks.filter {
        request.taskIDs.contains($0.id) && $0.archived && !$0.isPopoutDraft
      }.map(\.id))
      let retained = library.managedWorktreesReleased(deleting: eligible).filter {
        $0.archivedPruned != true
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
    if let managed = library.managedWorktrees.first(where: { $0.containsTask(taskID) }),
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
    deleteTasks(taskIDs, archivedOnly: true, validatedManaged: validatedManaged)
  }

  /// Direct deletion is called only after reserving the target and confirming it has stopped.
  @discardableResult func deleteTasks(_ taskIDs: Set<String>, archivedOnly: Bool,
    validatedManaged: Set<String> = []) -> Bool {
    guard !taskIDs.isEmpty else { return true }
    guard !managedTaskPreparing else {
      archivedTaskDeletionError = "工作树操作尚未完成，请稍后删除任务。"
      return false
    }
    do {
      var candidate = library
      let originalTaskCount = candidate.tasks.count
      let originalTaskIDs = Set(candidate.tasks.map(\.id))
      let eligible = Set(candidate.tasks.filter {
        taskIDs.contains($0.id) && (archivedOnly ? $0.archived && !$0.isPopoutDraft : !$0.isTransient)
      }.map(\.id))
      if !archivedOnly, eligible.contains(where: { activeRun(taskID: $0) != nil }) {
        throw AgentFailure(message: "任务尚未停止，不能删除。")
      }
      guard !candidate.managedWorktrees.contains(where: {
        !$0.associatedTaskIDs.isDisjoint(with: eligible) && $0.pendingHandoff != nil
      }) else { throw AgentFailure(message: "工作树仍有未完成的移交，请先恢复任务。") }
      let managed = candidate.managedWorktreesReleased(deleting: eligible)
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
            let title = candidate.managedTasks(for: record).first?.title
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
            candidate.projectNames[record.path] = candidate.managedTasks(for: record).first?.title ?? record.checkout.title
          }
        }
        candidate.newTaskExecutions[record.taskID] = nil
        candidate.pendingManagedDraftTaskIDs = candidate.pendingManagedDraftTaskIDs.filter {
          $0.value != record.taskID
        }
      }
      let releasedKeys = Set(managed.map(\.taskID))
      candidate.managedWorktrees.removeAll { releasedKeys.contains($0.taskID) }
      for index in candidate.managedWorktrees.indices {
        candidate.managedWorktrees[index].sharedTaskIDs =
          candidate.managedWorktrees[index].sharedTaskIDs?.filter { !eligible.contains($0) }
      }
      let alreadyPending = Set(candidate.pendingManagedWorktreeDeletions.map(\.taskID))
      candidate.pendingManagedWorktreeDeletions.append(contentsOf: managed.filter {
        !alreadyPending.contains($0.taskID)
      })
      // Archive is only a candidate eligibility marker; never publish an intermediate archive.
      if !archivedOnly {
        for index in candidate.tasks.indices where eligible.contains(candidate.tasks[index].id) {
          candidate.tasks[index].archived = true
        }
      }
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
      runs.removeAll { deletedRuns.contains($0.id) }
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
      archivedTaskDeletionError = "无法删除\(archivedOnly ? "归档任务" : "任务")：\(error.localizedDescription)"
      return false
    }
  }
}
