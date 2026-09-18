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
    guard canChangeBranch, project.map(GitBranchService.canonicalRoot)?.path == snapshot.root.path else {
      branchChangeError = "请等待当前任务结束，并在原项目中操作。"
      return false
    }
    busy = true
    workspace.gitBusy = true
    branchChangeError = nil
    defer { busy = false; workspace.gitBusy = false }
    do {
      try await GitBranchService.apply(change, snapshot: snapshot)
      await workspace.refreshFiles()
      await workspace.refreshGit()
      if let selectedFile = workspace.selectedFile { await workspace.openFile(selectedFile) }
      showingBranchPicker = false
      return true
    } catch {
      branchChangeError = error.localizedDescription
      if !showingBranchPicker { self.error = error.localizedDescription }
      return false
    }
  }
}
