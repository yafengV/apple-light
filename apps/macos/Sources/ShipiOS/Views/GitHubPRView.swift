import SwiftUI
import AppKit

struct GitHubPRView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  @Bindable var draft: GitHubPRDraft
  let taskID: String?
  @Environment(\.dismiss) private var dismiss
  @State private var summaryLoader = GitCommitSummaryLoader()
  @State private var selected: GitPullRequestAction = .create
  private enum Focus: Hashable { case title, body, action(GitPullRequestAction) }
  @FocusState private var focus: Focus?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if draft.loading { ProgressView("检查 GitHub、分支与 PR 状态…").controlSize(.small) }
      if let context = draft.context {
        HStack(spacing: 4) {
          Text(context.repository.fullName).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
          Text("·")
          Text(context.head).lineLimit(1).layoutPriority(1)
          Text("→")
          Text(draft.base).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
          Spacer(minLength: 0)
        }.appFont(.caption).foregroundStyle(.secondary).frame(height: 28)
        if draft.existing == nil {
          TextField("标题", text: $draft.title).textFieldStyle(.plain).fontWeight(.semibold)
            .accessibilityLabel("PR 标题")
            .focused($focus, equals: .title).disabled(draft.creating)
          TextEditor(text: $draft.body).scrollContentBackground(.hidden).frame(height: 70)
            .overlay(alignment: .topLeading) {
              if draft.body.isEmpty {
                Text("描述（留空自动生成）").foregroundStyle(.tertiary)
                  .padding(.top, 4).padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
              }
            }
            .accessibilityLabel("PR 描述").focused($focus, equals: .body).disabled(draft.creating)
          HStack {
            Toggle("提交并推送本地变更", isOn: $draft.includeLocalChanges)
              .toggleStyle(.checkbox).disabled(draft.creating)
            Spacer()
            if draft.includeLocalChanges, let summary = summaryLoader.summary {
              Text("+\(summary.additions)").foregroundStyle(.green)
              Text("−\(summary.deletions)").foregroundStyle(.red)
            }
          }.appFont(.caption)
          if draft.includeLocalChanges, let error = summaryLoader.error {
            Text(error).appFont(.caption).foregroundStyle(.orange)
          }
          if !draft.includeLocalChanges, context.publishedCommit == nil {
            Text("此分支尚未发布，请勾选提交并推送，或先推送分支。")
              .appFont(.caption).foregroundStyle(.orange)
          }
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
          ProgressView(draft.phase).controlSize(.small)
          if draft.generating { Button("取消生成") { draft.cancelGeneration() } }
        }
      }
      Divider()
      VStack(spacing: 3) {
        ForEach(actions) { action in
          Button { activate(action) } label: {
            HStack(spacing: 8) {
              Image(systemName: action.symbol).frame(width: 18)
              Text(action.title)
              Spacer()
              Text("⌘↩").appFont(.caption).foregroundStyle(.secondary)
                .opacity(selected == action ? 1 : 0)
            }.padding(.horizontal, 10).padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(selected == action ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
              .contentShape(Rectangle())
          }.buttonStyle(.plain).focused($focus, equals: .action(action))
            .disabled(!isEnabled(action))
            .accessibilityAddTraits(selected == action ? .isSelected : [])
            .onHover { hovering in if hovering && isEnabled(action) { selected = action } }
        }
      }.accessibilityElement(children: .contain).accessibilityLabel("PR 操作")
      if draft.error != nil || draft.needsRefresh {
        Button("重新检查") { refresh() }.controlSize(.small).disabled(draft.loading || draft.creating)
      }
    }.padding(12).frame(width: 420)
      .accessibilityLabel(draft.existing == nil ? "创建 PR" : "打开 PR")
      .background(PullRequestKeyboardBridge(action: handleKey).frame(width: 0, height: 0))
      .interactiveDismissDisabled(draft.creating)
      .task {
        selected = .initial(existing: draft.existing != nil,
          defaultToDraft: store.library.gitPreferences.createDraftPullRequests)
        await refreshExisting()
        if !draft.creating { focus = draft.existing == nil ? .title : .action(.openExisting) }
      }
      .onChange(of: draft.existing != nil) { _, existing in
        selected = .initial(existing: existing,
          defaultToDraft: store.library.gitPreferences.createDraftPullRequests)
        if existing { focus = .action(.openExisting) }
      }
      .onChange(of: focus) { _, value in
        if case .action(let action) = value { selected = action }
      }
      .task(id: summaryRequest) { await summaryLoader.load(summaryRequest) }
      .onDisappear { draft.modalDidDisappear() }
  }

  private var canCreate: Bool {
    draft.canCreate && workspace.isPrimaryReviewRepository
      && !store.library.gitPreferences.readOnlyReview && !workspace.gitBusy && !workspace.gitActionRunning
  }
  private var summaryRequest: GitCommitSummaryRequest {
    .init(root: workspace.gitRoot, includeUnstaged: true, revision: workspace.reviewSnapshot)
  }
  private func refresh() {
    Task { await refreshExisting() }
  }
  private func refreshExisting() async {
    guard workspace.isPrimaryReviewRepository, let root = workspace.gitRoot else { return }
    await draft.load(at: root, allowUnpublished: true)
    if let existing = draft.existing, let repository = draft.context?.repository,
      workspace.gitRoot == root {
      if let project = workspace.root {
        _ = store.recordPullRequest(existing, for: taskID, at: project, repository: repository)
      }
    }
  }
  private var actions: [GitPullRequestAction] {
    draft.existing == nil ? GitPullRequestAction.creationActions : [.openExisting]
  }
  private func isEnabled(_ action: GitPullRequestAction) -> Bool {
    if action == .openExisting {
      return !draft.loading && !draft.creating
        && draft.existing.flatMap { draft.context?.repository.pullRequestURL($0.url) } != nil
    }
    return canCreate
  }
  private func handleKey(_ key: PullRequestKeyboardBridge.Key) {
    switch key {
    case .cancel: if !draft.creating { dismiss() }
    case .activate: activate(selected)
    case .move(let delta):
      let next = selected.moved(by: delta, existing: draft.existing != nil)
      if isEnabled(next) {
        selected = next
        if case .action = focus { focus = .action(selected) }
      }
    }
  }
  private func activate(_ action: GitPullRequestAction) {
    guard isEnabled(action) else { return }
    selected = action
    if action == .openExisting {
      guard let existing = draft.existing, let url = draft.context?.repository.pullRequestURL(existing.url) else { return }
      if NSWorkspace.shared.open(url) { dismiss() }
      else { draft.reportError("无法打开系统浏览器，请重试。") }
      return
    }
    Task {
      await store.createPullRequest(in: workspace, draft: action == .createDraft, taskID: taskID,
        openInBrowser: action == .openBrowser)
    }
    dismiss()
  }
}
