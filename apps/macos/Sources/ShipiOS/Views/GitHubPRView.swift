import SwiftUI
import AppKit

struct GitHubPRView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  @Bindable var draft: GitHubPRDraft
  let taskID: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("创建 PR").appFont(.title2)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(draft.creating)
      }
      if draft.loading { ProgressView("检查 GitHub、分支与 PR 状态…").controlSize(.small) }
      if let context = draft.context {
        Text(context.repository.fullName).appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Label(context.head, systemImage: "arrow.triangle.branch").lineLimit(1)
          Image(systemName: "arrow.right")
          TextField("目标分支", text: $draft.base).disabled(draft.creating || draft.existing != nil)
        }
        if let existing = draft.existing {
          Text("此分支已有 PR #\(existing.number)").appFont(.headline)
          Text(existing.title).textSelection(.enabled)
          if existing.isDraft { Text("草稿 PR").appFont(.caption).foregroundStyle(.secondary) }
          Button("在浏览器中打开 PR") {
            if let url = context.repository.pullRequestURL(existing.url) { NSWorkspace.shared.open(url) }
          }
        } else {
          TextField("标题", text: $draft.title).accessibilityLabel("PR 标题").disabled(draft.creating)
          Text("描述（留空自动生成）").appFont(.caption)
          TextEditor(text: $draft.body).frame(height: 150).border(.secondary.opacity(0.3))
            .accessibilityLabel("PR 描述").disabled(draft.creating)
          if let problem = context.creationProblem {
            Text(problem).appFont(.caption).foregroundStyle(.orange)
          }
        }
      }
      if let error = draft.error {
        ScrollView { Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
      }
      if draft.context == nil && !draft.loading {
        Link("安装 GitHub CLI", destination: URL(string: "https://cli.github.com/")!)
        Text("安装后在终端运行 gh auth login，登录 GitHub 账户。")
          .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if draft.creating {
        HStack {
          ProgressView(draft.generating ? "正在生成 PR 内容…" : "正在创建 PR…").controlSize(.small)
          if draft.generating { Button("取消生成") { draft.cancelGeneration() } }
        }
      }
      Divider()
      HStack {
        Button("重新检查") { refresh() }.disabled(draft.loading || draft.creating)
        Spacer()
        if draft.existing == nil {
          Button(store.library.gitPreferences.createDraftPullRequests ? "创建草稿 PR" : "创建 PR") {
            submit(draft: store.library.gitPreferences.createDraftPullRequests)
          }.keyboardShortcut(.return, modifiers: .command).disabled(!canCreate)
          Menu {
            Button("创建草稿 PR") { submit(draft: true) }
            Button("创建 PR") { submit(draft: false) }
          } label: { Image(systemName: "chevron.down") }
            .fixedSize().disabled(!canCreate).accessibilityLabel("PR 创建方式")
        }
      }
    }.padding(24).frame(width: 530)
      .interactiveDismissDisabled(draft.creating)
      .task { await refreshExisting() }
      .onDisappear { draft.cancelLoading() }
  }

  private var canCreate: Bool {
    draft.canCreate && !store.library.gitPreferences.readOnlyReview && !workspace.gitBusy && !workspace.gitActionRunning
  }
  private func refresh() {
    Task { await refreshExisting() }
  }
  private func refreshExisting() async {
    guard let root = workspace.root else { return }
    await draft.load(at: root)
    if let existing = draft.existing, let repository = draft.context?.repository,
      workspace.root == root {
      _ = store.recordPullRequest(existing, for: taskID, at: root, repository: repository)
    }
  }
  private func submit(draft: Bool) {
    Task { await store.createPullRequest(in: workspace, draft: draft, taskID: taskID) }
  }
}
