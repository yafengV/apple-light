import SwiftUI

struct ActivityArchiveDialog: View {
  let store: WorkspaceStore
  let request: ActivityArchiveRequest
  var body: some View {
    let stop = store.activityArchiveNeedsStop
    let single = request.scope == .task
    SettingsConfirmationDialog(
      title: single ? (stop ? "停止并归档此任务？" : "归档此任务？") : stop ? "停止并归档 \(request.taskIDs.count) 个任务？"
        : "归档 \(request.taskIDs.count) 个优先任务？",
      message: stop ? "归档会停止这些任务正在进行的工作。之后可在设置中恢复任务。"
        : single ? "之后可在设置中恢复任务。" : "近期列表中的任务不会被归档。之后可在设置中恢复任务。",
      confirmLabel: stop ? "停止并归档" : "归档", busyLabel: "正在归档…",
      busy: store.archivingActivity, error: nil, width: 440,
      identifier: "activity-archive-dialog", cancel: store.dismissActivityArchive,
      confirm: { Task { await store.confirmActivityArchive() } })
  }
}
