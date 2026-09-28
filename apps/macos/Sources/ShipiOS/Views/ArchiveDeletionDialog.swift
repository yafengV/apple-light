import SwiftUI

struct ArchiveDeletionDialog: View {
  let store: WorkspaceStore
  let request: ArchiveDeletionRequest
  var body: some View {
    let managed = store.library.managedWorktreesReleased(deleting: request.taskIDs)
    let stopping = request.kind == .task && request.taskIDs.contains { store.activeRun(taskID: $0) != nil }
    let explanation = request.message + (stopping ? " 确认后将先停止正在进行的工作。" : "")
    let shared = store.library.managedWorktrees.contains {
      !$0.associatedTaskIDs.isDisjoint(with: request.taskIDs) && !managed.contains($0)
    }
    let sharedExplanation = explanation + (shared ? " 其他任务共用的工作树将继续保留。" : "")
    let message = managed.isEmpty ? sharedExplanation : sharedExplanation
      + " 已清理的托管工作树快照也会删除；仍在磁盘的工作树将保留为独立项目。"
    SettingsConfirmationDialog(title: request.title, message: message,
      confirmLabel: "删除", busyLabel: "正在删除…", busy: store.deletingArchive,
      error: store.archivedTaskDeletionError, width: 520, identifier: "archive-deletion-dialog",
      cancel: { store.dismissArchiveDeletion(requestID: request.id) },
      confirm: { Task { await store.confirmArchiveDeletion(requestID: request.id) } })
  }
}
