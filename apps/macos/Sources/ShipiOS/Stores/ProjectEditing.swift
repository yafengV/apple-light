import Foundation

extension WorkspaceStore {
  func beginEditingProject(_ path: String) {
    guard libraryLoaded, !restoringLibrary, !shuttingDown, !busy,
      presentedOverlay == nil, !hasSettingsConfirmation, renameTaskID == nil,
      editingProject == nil, library.projects.contains(path) else { return }
    showingModelPicker = false
    showingBranchPicker = false
    editingProject = ProjectEditRequest(project: path, title: library.projectTitle(path),
      folders: Array(library.configuredFolders(for: path).dropFirst()),
      primary: library.primaryFolder(for: path))
  }

  func saveProjectEdit(_ request: ProjectEditRequest, title: String, folders: [String],
    primary: String? = nil) throws {
    guard editingProject?.id == request.id, libraryLoaded, !shuttingDown,
      library.projects.contains(request.project) else {
      throw AgentFailure(message: "项目编辑已失效，请重新打开。")
    }
    guard library.projectTitle(request.project) == request.title,
      Array(library.configuredFolders(for: request.project).dropFirst()) == request.folders,
      library.primaryFolder(for: request.project) == request.primaryPath else {
      throw AgentFailure(message: "项目已在其他位置修改，请重新打开编辑。")
    }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AgentFailure(message: "请填写项目名称。") }
    let validated = try ProjectFolders.canonical([primary ?? request.primaryPath] + folders)
    let selectedPrimary = validated[0]
    if selectedPrimary != request.primaryPath,
      (library.pendingManagedDraftTaskIDs.keys.contains(where: {
        library.projectOwner(for: $0) == request.project
      }) || library.pendingPopoutWorktreeTaskIDs.keys.contains(where: {
        library.projectOwner(for: $0) == request.project
      })) {
      throw AgentFailure(message: "此项目还有待恢复的工作树任务，请先恢复任务再更改主目录。")
    }
    guard !library.isKnownProjectScope(selectedPrimary)
      || library.projectOwner(for: selectedPrimary) == request.project else {
      throw AgentFailure(message: "此文件夹已属于另一个项目，无法替换为当前项目的主目录。")
    }
    var candidate = library
    candidate.projectNames[request.project] = String(name.prefix(120))
    candidate.projectPrimaryFolders[request.project] = selectedPrimary == request.project ? nil : selectedPrimary
    if selectedPrimary != request.project {
      candidate.projectScopeOwners[selectedPrimary] = request.project
    }
    candidate.projectAdditionalFolders[request.project] = Array(validated.dropFirst())
    try commitLibrary(candidate)
  }

  /// Project edits change defaults; ordinary task scopes and their running tools stay fixed.
  @discardableResult func applyPrimaryToNewTask() async -> Bool {
    guard selectedTask == nil, let project else { return true }
    let primary = library.primaryFolder(for: project.path)
    guard primary != project.path else { return true }
    guard !busy, activeLocalRun == nil else { return false }
    let mode = chatMode
    let goal = pendingGoal
    let action = action
    await newTask(in: library.projectOwner(for: project.path))
    guard connected, self.project?.path == primary, selectedTask == nil else { return false }
    chatMode = mode
    pendingGoal = goal
    self.action = action
    return true
  }
}
