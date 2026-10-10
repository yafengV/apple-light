import SwiftUI

struct WorktreeForkPreparationView: View {
  let store: WorkspaceStore
  let presentation: WorktreeForkPresentation
  let preparation: WorktreeForkPreparation
  var back: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(action: back) { Image(systemName: "chevron.left") }
          .help("返回聊天").accessibilityLabel("返回聊天")
          .accessibilityIdentifier("worktree-fork-back")
        Text(preparation.title).lineLimit(1).appFont(size: 14, weight: .semibold)
        Spacer()
        if preparation.state == .preparing {
          Button("取消创建") { preparation.cancel() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("worktree-fork-cancel")
        }
      }.padding(16)
      Divider()
      Spacer(minLength: 24)
      VStack(alignment: .leading, spacing: 16) {
        if preparation.state == .preparing {
          HStack(spacing: 12) { ProgressView().controlSize(.small); Text(preparation.phase) }
        } else if case .failed(let message) = preparation.state {
          Label("工作树分支尚未准备完成", systemImage: "exclamationmark.triangle")
          Text(message).foregroundStyle(.secondary).textSelection(.enabled)
        } else if preparation.state == .cancelled {
          Label("已取消创建", systemImage: "stop.circle")
          Text(preparation.taskID.map { id in store.library.managedWorktrees.contains { $0.taskID == id } } == true
            ? "已保存的工作树和聊天历史会保留，可以继续创建。" : "来源聊天和草稿已保留，可以重试创建。")
            .foregroundStyle(.secondary)
        } else { Label("工作树分支已准备完成", systemImage: "checkmark.circle") }
        if let path = preparation.path {
          Text(path).appFont(size: 12, design: .monospaced).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if preparation.state != .preparing && preparation.state != .ready {
          Button("继续创建") { Task { await store.retryWorktreeFork(in: presentation) } }
            .buttonStyle(.bordered)
            .disabled(store.managedTaskPreparing || store.busy)
            .accessibilityIdentifier("worktree-fork-retry")
        } else if preparation.state == .ready {
          Button("打开聊天") { Task { await store.openPreparedWorktreeFork(in: presentation) } }
            .buttonStyle(.bordered)
            .disabled(store.busy).accessibilityIdentifier("worktree-fork-open")
        }
      }.frame(maxWidth: 560, alignment: .leading).padding(24)
      Spacer(minLength: 24)
    }.frame(maxWidth: .infinity, maxHeight: .infinity).appSurface()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("worktree-fork-preparation")
      .onExitCommand(perform: back)
  }
}
