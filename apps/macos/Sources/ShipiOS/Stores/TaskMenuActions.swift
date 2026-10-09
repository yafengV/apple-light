import AppKit

enum TaskMenuCopy { case workingDirectory, link, markdown }

extension WorkspaceStore {
  /// Menu actions resolve the latest task instead of selecting it or using a stale row snapshot.
  func taskMenuTarget(_ id: String) -> WorkspaceTask? {
    guard libraryLoaded, !restoringLibrary, !shuttingDown, !hasSettingsConfirmation,
      presentedOverlay == nil, !mainRenameDialogActive, renameProjectPath == nil,
      !showingModelPicker, !showingBranchPicker,
      !activityArchivingTaskIDs.contains(id),
      let task = library.tasks.first(where: { $0.id == id }), !task.isTransient else { return nil }
    return task
  }

  func renameTaskFromMenu(_ id: String) {
    guard taskMenuTarget(id) != nil else { return }
    beginRenamingTask(id)
  }

  func renameTaskFromRowTitle(_ id: String) {
    guard destination == .workspace, selectedTask?.id == id,
      let task = taskMenuTarget(id), !task.archived else { return }
    beginRenamingTask(task.id)
  }

  func toggleTaskPinFromMenu(_ id: String) {
    guard let task = taskMenuTarget(id) else { return }
    var candidate = library
    candidate.moveSidebarItem(.task(id), to: task.pinned
      ? SidebarLayout.project(candidate.sidebarProject(for: task)) : SidebarLayout.pinned)
    do { try commitLibrary(candidate) }
    catch { if showingActivity { activityError = error.localizedDescription }; self.error = error.localizedDescription }
  }

  func toggleTaskReadFromMenu(_ id: String) {
    guard let task = taskMenuTarget(id) else { return }
    let unread = !library.unreadTasks.contains(id)
    var candidate = library
    if unread { candidate.unreadTasks.insert(id) } else { candidate.unreadTasks.remove(id) }
    do {
      try commitLibrary(candidate)
      if showingActivity, !unread { reviewActivityAutomation(task) }
    } catch { if showingActivity { activityError = error.localizedDescription }; self.error = error.localizedDescription }
  }

  func taskMenuWorkingDirectory(_ task: WorkspaceTask) -> String? {
    if !task.project.isEmpty { return task.project }
    return library.projectlessTaskDirectories[task.id]
  }

  @discardableResult func openTaskInNewWindow(_ id: String) -> Bool {
    guard !busy, !managedTaskPreparing,
      let task = taskMenuTarget(id), !task.archived else { return false }
    taskWindowOpenRequest = .newWindow(taskID: id, dataRoot: dataRoot)
    return true
  }

  func copyTaskFromMenu(_ id: String, content: TaskMenuCopy) {
    guard let task = taskMenuTarget(id) else { return }
    switch content {
    case .link: copyTaskDeepLink(task)
    case .markdown: copyTaskTranscript(task)
    case .workingDirectory:
      guard let path = taskMenuWorkingDirectory(task) else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(path, forType: .string)
    }
  }
}
