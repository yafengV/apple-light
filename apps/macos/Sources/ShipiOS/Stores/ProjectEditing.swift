import Foundation

extension WorkspaceStore {
  func beginEditingProject(_ path: String) {
    guard libraryLoaded, !restoringLibrary, !shuttingDown, !busy,
      presentedOverlay == nil, !hasSettingsConfirmation, renameTaskID == nil,
      editingProject == nil, library.projects.contains(path) else { return }
    showingModelPicker = false
    showingBranchPicker = false
    editingProject = ProjectEditRequest(project: path, title: library.projectTitle(path),
      folders: library.additionalFolders(for: path))
  }

  func saveProjectEdit(_ request: ProjectEditRequest, title: String, folders: [String]) throws {
    guard editingProject?.id == request.id, libraryLoaded, !shuttingDown,
      library.projects.contains(request.project) else {
      throw AgentFailure(message: "项目编辑已失效，请重新打开。")
    }
    guard library.projectTitle(request.project) == request.title,
      library.additionalFolders(for: request.project) == request.folders else {
      throw AgentFailure(message: "项目已在其他位置修改，请重新打开编辑。")
    }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AgentFailure(message: "请填写项目名称。") }
    let validated = try ProjectFolders.canonical([request.project] + folders)
    var candidate = library
    candidate.projectNames[request.project] = String(name.prefix(120))
    candidate.projectAdditionalFolders[request.project] = Array(validated.dropFirst())
    try commitLibrary(candidate)
  }
}
