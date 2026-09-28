import Foundation

extension WorkspaceStore {
  func openProjectPicker(createNewTask: Bool) {
    guard commandEnabled("project-picker") else { return }
    projectPickerCreatesNewTask = createNewTask
    setOverlay(.projectPicker, presented: true)
  }

  func chooseProjectFromPicker(_ option: ProjectPickerOption) async {
    guard presentedOverlay == .projectPicker, destination == .workspace,
      activeLocalRun == nil, !busy, libraryLoaded else { return }
    if case .project(let path) = option, !library.projects.contains(path) { return }
    let createsNewTask = projectPickerCreatesNewTask
    setOverlay(.projectPicker, presented: false)
    searchDialogReturnFocus = nil
    fileFocusAfterOverlay = nil
    switch option {
    case .project(let path):
      if createsNewTask { await newTask(in: path) }
      else { await open(URL(fileURLWithPath: path)) }
    case .projectless:
      if createsNewTask { await newProjectlessTask() }
      else { await openProjectless() }
    case .addFolder: chooseProject(createNewTask: createsNewTask)
    }
  }

  func renameTask(_ id: String, title: String) throws {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { throw AgentFailure(message: "请填写任务名称。") }
    try persistTaskTitle(id, title: String(cleaned.prefix(120)))
  }

  /// Undo restores the exact prior title, including names imported from older versions.
  func persistTaskTitle(_ id: String, title: String) throws {
    guard libraryLoaded else { throw AgentFailure(message: "工作区尚未加载完成。") }
    var candidate = library
    guard let index = candidate.tasks.firstIndex(where: { $0.id == id }) else {
      throw AgentFailure(message: "任务已经不存在，无法重命名。")
    }
    candidate.tasks[index].title = title
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
    let primary = library.primaryFolder(for: path)
    guard !busy, project?.path == primary || activeLocalRun == nil else { return }
    let switching = project?.path != primary || !connected
    if switching {
      recordNavigation()
      await open(URL(fileURLWithPath: path))
    }
    guard connected, project?.path == primary else { return }
    library.collapsedProjects.remove(library.projectOwner(for: path))
    newTask(recordHistory: !switching)
    rememberProjectSelection()
    saveLibrary()
  }
}
