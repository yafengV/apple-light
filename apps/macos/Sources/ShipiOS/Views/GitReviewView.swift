import SwiftUI

struct GitReviewView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  var taskID: String?
  var focusComposer: (() -> Void)?
  var body: some View {
    VStack(spacing: 0) {
      if workspace.gitAvailable {
        HStack {
          if taskID == nil {
            Button { store.openBranchPicker() } label: {
              Label(workspace.gitBranch, systemImage: "arrow.triangle.branch").lineLimit(1)
            }.buttonStyle(.plain).disabled(!store.canChangeBranch).help("切换或创建分支")
          } else {
            Label(workspace.gitBranch, systemImage: "arrow.triangle.branch").lineLimit(1)
          }
          Spacer()
          if workspace.gitBusy {
            ProgressView().controlSize(.small).accessibilityLabel("正在处理 Git 变更")
          }
          Button {
            Task { await workspace.refreshGit() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.plain).help("刷新变更").accessibilityLabel("刷新变更")
            .disabled(workspace.gitRefreshing || workspace.gitBusy)
        }.appFont(.caption).padding(12)
        Picker("变更范围", selection: $workspace.reviewScope) {
          ForEach(GitReviewScope.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).padding(.horizontal, 12).padding(.bottom, 8)
        if store.library.gitPreferences.readOnlyReview {
          Label("只读审查", systemImage: "lock")
            .appFont(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
        }
        revisionPicker
        if !workspace.reviewScope.isHistorical && !store.library.gitPreferences.readOnlyReview {
          HStack {
            Text("\(workspace.visibleChanges.count) 个文件").appFont(.caption).foregroundStyle(
              .secondary)
            Spacer()
            Button(workspace.reviewScope == .staged ? "全部取消暂存" : "全部暂存") {
              if let snapshot = workspace.batchSnapshot {
                Task { await workspace.stageAll(snapshot) }
              }
            }.controlSize(.small)
              .disabled(
                workspace.batchSnapshot?.paths.isEmpty != false || workspace.gitBusy
                  || workspace.reviewLoading || workspace.gitRefreshing)
            if workspace.reviewScope == .unstaged {
              Button("撤销全部") {
                if let snapshot = workspace.batchSnapshot {
                  Task { await workspace.prepareDiscard(snapshot) }
                }
              }.controlSize(.small)
                .disabled(
                  workspace.batchSnapshot?.paths.isEmpty != false || workspace.gitBusy
                    || workspace.reviewLoading || workspace.gitRefreshing)
            }
          }.padding(.horizontal, 12).padding(.bottom, 8)
          if let error = workspace.batchError {
            Text("批量操作暂不可用：" + error).appFont(.caption).foregroundStyle(.secondary).padding(
              .horizontal, 12)
          }
        }
        if workspace.reviewLoading {
          ProgressView("读取变更…").controlSize(.small).padding(8)
        } else if workspace.visibleChanges.isEmpty && workspace.error == nil {
          Text(emptyMessage).appFont(.caption).foregroundStyle(.secondary).padding()
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if !workspace.reviewLoading && !workspace.gitRefreshing
              && !workspace.reviewArguments.isEmpty, let root = workspace.root
            {
              ForEach(workspace.visibleChanges) { file in
                ReviewFileView(
                  store: store, workspace: workspace, file: file, root: root,
                  scope: workspace.reviewScope, revision: reviewRevision, taskID: taskID
                )
                .id(root.path + ":" + reviewSelection + ":" + file.path)
              }
            }
          }.padding(10)
        }.frame(maxHeight: .infinity)
        if !store.reviewComments(taskID: taskID).isEmpty {
          HStack {
            Text("\(store.reviewComments(taskID: taskID).count) 条待发送评论").appFont(.caption)
            Spacer()
            Button("撰写后续消息") {
              if let focusComposer { focusComposer() }
              else {
                store.action = .chat
                store.focusComposer = UUID()
              }
            }
            .appFont(.caption)
          }.padding(10)
        }
        if let error = workspace.error {
          Text(error).appFont(.caption).foregroundStyle(.orange).padding(10)
        }
        if !workspace.reviewScope.isHistorical && !store.library.gitPreferences.readOnlyReview {
          if !workspace.canCommit {
            Text("提交整个仓库前，请先打开仓库根目录以审查全部暂存内容。").appFont(.caption).foregroundStyle(.secondary)
              .padding(
                10)
          }
          HStack {
            if let status = workspace.gitActionStatus {
              Text(status).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("创建 PR…") { workspace.showingPullRequest = true }
              .disabled(!workspace.canCommit || workspace.gitBusy || workspace.gitActionRunning)
            Button("提交或推送…") { workspace.showingCommitPush = true }
              .disabled(!workspace.canCommit || workspace.gitBusy || workspace.gitRefreshing)
          }.padding(10)
        }
      } else {
        ContentUnavailableView(
          "当前项目没有 Git 仓库", systemImage: "arrow.triangle.branch",
          description: Text("在终端初始化或打开已有 Git 项目后查看变更。"))
      }
    }.onDisappear { workspace.cancelCommitMessageGeneration() }
    .sheet(isPresented: $workspace.showingCommitPush) {
      GitCommitPushView(store: store, workspace: workspace,
        taskTitle: store.gitCommitTaskTitle(taskID: taskID))
    }
    .sheet(isPresented: $workspace.showingPullRequest) {
      GitHubPRView(store: store, workspace: workspace, draft: workspace.pullRequestDraft)
    }
    .onChange(of: store.library.gitPreferences.readOnlyReview) { _, readOnly in
      if readOnly { workspace.cancelCommitMessageGeneration() }
    }
    .onChange(of: reviewSelection) { _, _ in
      workspace.cancelCommitMessageGeneration()
      workspace.discardPlan = nil
      workspace.reviewPath = nil
      Task { await workspace.loadDiff() }
    }
    .alert(
      "撤销未暂存修改？",
      isPresented: Binding(
        get: { workspace.discardPlan != nil },
        set: { if !$0 { workspace.discardPlan = nil } }), presenting: workspace.discardPlan
    ) { plan in
      Button("撤销变更", role: .destructive) { Task { await workspace.discard(plan) } }
      Button("取消", role: .cancel) { workspace.discardPlan = nil }
    } message: { plan in
      Text(plan.message)
    }
  }

  private var reviewRevision: String {
    workspace.reviewArguments.joined(separator: " ")
  }

  private var reviewSelection: String {
    workspace.reviewScope.rawValue + ":"
      + (workspace.reviewScope == .commit ? workspace.reviewCommit : workspace.reviewBaseBranch)
  }

  @ViewBuilder private var revisionPicker: some View {
    if workspace.reviewScope == .commit {
      Picker("提交记录", selection: $workspace.reviewCommit) {
        if workspace.reviewCommits.isEmpty { Text("尚无提交").tag("") }
        ForEach(workspace.reviewCommits) { Text($0.title).tag($0.id) }
      }.padding(.horizontal, 12).padding(.bottom, 8)
      Text("最近 100 次提交；合并提交与其第一个父提交比较。")
        .appFont(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
    } else if workspace.reviewScope == .branch {
      Picker("基准分支", selection: $workspace.reviewBaseBranch) {
        Text("选择基准分支").tag("")
        ForEach(workspace.reviewBranches) { Text($0.title).tag($0.id) }
      }.padding(.horizontal, 12).padding(.bottom, 8)
      Text("显示从共同祖先到当前 HEAD 的已提交变更。")
        .appFont(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
    }
  }

  private var emptyMessage: String {
    switch workspace.reviewScope {
    case .commit where workspace.reviewCommits.isEmpty: "此仓库尚无提交"
    case .branch where workspace.reviewBaseBranch.isEmpty: "选择一个基准分支以查看变更"
    default: "没有此类变更"
    }
  }
}
