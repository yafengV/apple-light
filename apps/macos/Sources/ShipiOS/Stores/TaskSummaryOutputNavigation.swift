import Foundation

extension WorkspaceStore {
  /// Reveal an output in this window's native file preview when its run belongs here.
  @discardableResult func revealTaskSummaryFile(_ file: TaskSummaryLinkedFile) -> Bool {
    guard let task = selectedTask, task.runIDs.contains(file.runID),
      let root = workspace.root, let path = file.previewPath(in: root) else { return false }
    showPane("files")
    workspace.selectFile(path)
    return true
  }
}
