import SwiftUI

struct GitReviewEmptyView: View {
  @Bindable var workspace: DeveloperWorkspace

  var body: some View {
    ContentUnavailableView {
      Label(workspace.root == nil ? "选择项目以查看变更" : "当前项目没有 Git 仓库",
        systemImage: "arrow.triangle.branch")
    } description: {
      Text(workspace.root == nil ? "打开一个项目后即可审查代码变更。" : "创建 Git 仓库以查看、暂存和提交项目变更。")
      if let error = workspace.error {
        Text(error).foregroundStyle(.orange).textSelection(.enabled)
      }
      if workspace.root != nil && workspace.isGitReviewReadOnly() {
        Text("当前审查为只读。请在代码审查设置中关闭只读后创建仓库。")
      }
    } actions: {
      if let root = workspace.root {
        if workspace.gitBusy {
          ProgressView("正在创建 Git 仓库…").controlSize(.small)
        } else if workspace.gitRefreshing {
          ProgressView("正在检查 Git 仓库…").controlSize(.small)
        }
        Button("创建 Git 仓库") {
          Task { await workspace.initializeGit(at: root) }
        }
        .disabled(!workspace.canInitializeGit)
        Button("刷新") { Task { await workspace.refreshGit() } }
          .disabled(workspace.gitBusy || workspace.gitRefreshing)
      }
    }
  }
}
