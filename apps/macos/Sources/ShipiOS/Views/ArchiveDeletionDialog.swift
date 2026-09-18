import SwiftUI

struct ArchiveDeletionDialog: View {
  let store: WorkspaceStore
  let request: ArchiveDeletionRequest
  var body: some View {
    SettingsConfirmationDialog(title: request.title, message: request.message,
      confirmLabel: "删除", busyLabel: "正在删除…", busy: store.deletingArchive,
      error: store.archivedTaskDeletionError, width: 520, identifier: "archive-deletion-dialog",
      cancel: store.dismissArchiveDeletion,
      confirm: { Task { await store.confirmArchiveDeletion() } })
  }
}
