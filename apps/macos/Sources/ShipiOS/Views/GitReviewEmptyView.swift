import SwiftUI

struct GitReviewEmptyView: View {
  @Bindable var workspace: DeveloperWorkspace

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: workspace.gitReadError == nil ? "arrow.triangle.branch" : "exclamationmark.triangle")
    } description: {
      Text(description)
      if let error = workspace.gitReadError ?? workspace.error {
        Text(error).foregroundStyle(.orange).textSelection(.enabled)
      }
      if workspace.root != nil && workspace.gitReadError == nil && !workspace.gitRefreshing
        && workspace.isGitReviewReadOnly() {
        Text("当前审查为只读。请在代码审查设置中关闭只读后创建仓库。")
      }
    } actions: {
      if let root = workspace.root {
        if workspace.gitBusy {
          ProgressView("正在创建 Git 仓库…").controlSize(.small)
        } else if workspace.gitRefreshing {
          ProgressView("正在检查 Git 仓库…").controlSize(.small)
        }
        if workspace.gitReadError == nil && !workspace.gitRefreshing {
          Button("创建 Git 仓库") {
            Task { await workspace.initializeGit(at: root) }
          }
          .disabled(!workspace.canInitializeGit)
        }
        Button(workspace.gitReadError == nil ? "刷新" : "重试") { Task { await workspace.refreshGit() } }
          .disabled(workspace.gitBusy || workspace.gitRefreshing)
      }
    }
  }

  private var title: String {
    if workspace.root == nil { return "选择项目以查看变更" }
    if workspace.gitRefreshing { return "正在检查 Git 仓库" }
    if workspace.gitReadError != nil { return "无法读取 Git 仓库" }
    return "当前项目没有 Git 仓库"
  }

  private var description: String {
    if workspace.root == nil { return "打开一个项目后即可审查代码变更。" }
    if workspace.gitReadError != nil { return "请解决下方读取错误后重试。" }
    if workspace.gitRefreshing { return "正在读取项目的仓库状态。" }
    return "创建 Git 仓库以查看、暂存和提交项目变更。"
  }
}
