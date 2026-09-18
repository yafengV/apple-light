import Foundation

extension WorkspaceStore {
  func renameTask(_ id: String, title: String) throws {
    guard libraryLoaded else { throw AgentFailure(message: "工作区尚未加载完成。") }
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { throw AgentFailure(message: "请填写任务名称。") }
    var candidate = library
    guard let index = candidate.tasks.firstIndex(where: { $0.id == id }) else {
      throw AgentFailure(message: "任务已经不存在，无法重命名。")
    }
    candidate.tasks[index].title = String(cleaned.prefix(120))
    candidate.tasks[index].updatedAt = Date()
    try commitLibrary(candidate)
  }

  func beginRenamingProject(_ path: String) {
    renameDraft = library.projectTitle(path)
    renameTaskID = nil
    renameProjectPath = path
  }

  func beginRenamingTask(_ id: String) {
    guard let task = library.tasks.first(where: { $0.id == id }) else { return }
    renameDraft = task.title
    renameProjectPath = nil
    renameTaskID = id
  }

  func canSelectTask(_ task: WorkspaceTask) -> Bool {
    !busy && (currentProjectKey == task.project || activeLocalRun == nil)
  }

  func rememberProjectSelection() {
    guard (scopeLoaded && project == nil) || connected else { return }
    library.projectSelections[currentProjectKey] = selection ?? ""
    library.lastWorkspace = currentProjectKey
  }

  func toggleProjectExpansion(_ path: String) {
    if library.collapsedProjects.contains(path) {
      library.collapsedProjects.remove(path)
    } else {
      library.collapsedProjects.insert(path)
    }
    saveLibrary()
  }

  func renameProject(_ path: String, title: String) {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard library.projects.contains(path), !value.isEmpty else { return }
    library.projectNames[path] = String(value.prefix(120))
    saveLibrary()
  }

  func newTask(in path: String) async {
    guard !busy, project?.path == path || activeLocalRun == nil else { return }
    let switching = project?.path != path || !connected
    if switching {
      recordNavigation()
      await open(URL(fileURLWithPath: path))
    }
    guard connected, project?.path == path else { return }
    library.collapsedProjects.remove(path)
    newTask(recordHistory: !switching)
    rememberProjectSelection()
    saveLibrary()
  }
}
