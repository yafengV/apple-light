import SwiftUI

struct ArchiveDeletionDialog: View {
  let store: WorkspaceStore
  let request: ArchiveDeletionRequest
  var body: some View {
    let managed = store.library.managedWorktrees.filter { request.taskIDs.contains($0.taskID) }
    let message = managed.isEmpty ? request.message : request.message
      + " 已清理的托管工作树快照也会删除；仍在磁盘的工作树将保留为独立项目。"
    SettingsConfirmationDialog(title: request.title, message: message,
      confirmLabel: "删除", busyLabel: "正在删除…", busy: store.deletingArchive,
      error: store.archivedTaskDeletionError, width: 520, identifier: "archive-deletion-dialog",
      cancel: store.dismissArchiveDeletion,
      confirm: { Task { await store.confirmArchiveDeletion() } })
  }
}
