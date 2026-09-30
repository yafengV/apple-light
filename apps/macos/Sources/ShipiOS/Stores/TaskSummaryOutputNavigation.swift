import Foundation

extension WorkspaceStore {
  /// Reveal an output in a file content tab when its run belongs here.
  @discardableResult func revealTaskSummaryFile(_ file: TaskSummaryLinkedFile) -> Bool {
    guard let task = selectedTask, task.runIDs.contains(file.runID),
      let root = workspace.root, let path = file.panePath(in: root) else { return false }
    return openFileTab(path)
  }
}
