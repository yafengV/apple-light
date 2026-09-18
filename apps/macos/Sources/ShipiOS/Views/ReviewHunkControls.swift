import SwiftUI

struct ReviewHunkControls: View {
  @Bindable var workspace: DeveloperWorkspace
  let file: GitFile
  let hunk: ReviewHunk
  let snapshot: ReviewDiff
  let project: URL
  let scope: GitReviewScope
  @State private var confirmingRevert = false

  var body: some View {
    HStack(spacing: 12) {
      Text(hunk.title).appFont(size: 11, design: .monospaced).foregroundStyle(.secondary)
      Button(scope == .staged ? "取消暂存此块" : "暂存此块") {
        apply(scope == .staged ? .unstage : .stage)
      }.buttonStyle(.borderless)
        .accessibilityLabel(
          "\(scope == .staged ? "取消暂存" : "暂存") \(file.path) 差异块 \(hunk.title)")
      if scope == .unstaged {
        Button("撤销此块") { confirmingRevert = true }.buttonStyle(.borderless)
          .accessibilityLabel("撤销 \(file.path) 差异块 \(hunk.title)")
      }
    }.appFont(.caption).padding(.horizontal, 10).padding(.vertical, 6)
      .disabled(workspace.gitBusy)
      .confirmationDialog("撤销此差异块？", isPresented: $confirmingRevert, titleVisibility: .visible) {
        Button("撤销未暂存的差异块", role: .destructive) { apply(.revert) }
        Button("取消", role: .cancel) {}
      } message: {
        Text("\(file.path)\n\(hunk.title)\n仅丢弃此块的未暂存修改，已暂存内容保留。此操作不能撤回。")
      }
  }
  private func apply(_ action: GitHunkAction) {
    Task {
      await workspace.applyHunk(
        action, file: file, hunk: hunk, snapshot: snapshot, project: project)
    }
  }
}
