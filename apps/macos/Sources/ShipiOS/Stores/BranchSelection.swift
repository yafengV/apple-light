import Foundation

extension WorkspaceStore {
  func openBranchPicker() {
    guard canChangeBranch else { return }
    presentedOverlay = nil
    showingModelPicker = false
    branchChangeError = nil
    showingBranchPicker = true
  }

  var canChangeBranch: Bool {
    destination == .workspace && project != nil && activeLocalRun == nil && !busy && !workspace.gitBusy
      && !workspace.gitActionRunning
  }

  @discardableResult func changeBranch(_ change: GitBranchChange, snapshot: GitBranchSnapshot) async -> Bool {
    guard canChangeBranch,
      project.map(GitBranchService.canonicalRoot)?.path == workspace.root.map(GitBranchService.canonicalRoot)?.path,
      workspace.gitRoot.map(GitBranchService.canonicalRoot)?.path == snapshot.root.path else {
      branchChangeError = "请等待当前任务结束，并在原项目中操作。"
      return false
    }
    let token = workspace.generationForGitMutation
    let originalProject = project
    let authorizeRepository = workspace.gitRepositoryAuthorization(at: snapshot.root)
    busy = true
    workspace.gitBusy = true
    branchChangeError = nil
    defer {
      if project == originalProject, workspace.generationForGitMutation == token {
        busy = false
        workspace.gitBusy = false
      }
    }
    do {
      try await GitBranchService.apply(change, snapshot: snapshot, authorize: {
        try authorizeRepository()
        try Task.checkCancellation()
        guard self.project == originalProject, self.workspace.generationForGitMutation == token,
          self.workspace.gitRoot.map(GitBranchService.canonicalRoot)?.path == snapshot.root.path else {
          throw CancellationError()
        }
      })
      guard project == originalProject, workspace.generationForGitMutation == token else { return false }
      await workspace.refreshFiles()
      await workspace.refreshGit()
      if let selectedFile = workspace.selectedFile { await workspace.openFile(selectedFile) }
      showingBranchPicker = false
      return true
    } catch {
      guard project == originalProject, workspace.generationForGitMutation == token,
        !(error is CancellationError) else { return false }
      branchChangeError = error.localizedDescription
      if !showingBranchPicker { self.error = error.localizedDescription }
      return false
    }
  }
}
