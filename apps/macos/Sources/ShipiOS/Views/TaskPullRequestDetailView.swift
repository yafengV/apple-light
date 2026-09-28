import AppKit
import SwiftUI

struct TaskPullRequestDetailView: View {
  let store: WorkspaceStore
  let taskID: String
  let request: GitHubPullRequest
  let root: URL
  let openExternal: (URL) -> Void
  let onRefresh: (GitHubPullRequest) -> Void
  let back: () -> Void
  let close: () -> Void
  var compact = true
  var presentations: PullRequestTabPresentations? = nil
  var tabID: String = ""

  @State private var state = GitHubPRDetailState()
  private var details: GitHubPRDetails? { state.snapshot?.details }
  private var valid: Bool {
    !store.restoringLibrary && !store.shuttingDown
      && store.library.tasks.contains { $0.id == taskID && $0.project == root.path }
      && store.library.taskPullRequests[taskID]?.contains {
        $0.validatedURL == request.validatedURL && $0.number == request.number && $0.validatedURL != nil
      } == true
  }
  private var writable: Bool { valid && !store.library.gitPreferences.readOnlyReview }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        if compact { Button(action: back) { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).help("返回摘要").accessibilityLabel("返回摘要")
        }
        Text("Pull request #\(request.number)").appFont(.headline).lineLimit(1)
        Spacer(minLength: 0)
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help(compact ? "关闭摘要" : "关闭 PR").accessibilityLabel(compact ? "关闭摘要" : "关闭 PR")
      }.padding(.horizontal, 16).padding(.vertical, 13)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Text(details?.title ?? request.title).appFont(.headline).textSelection(.enabled)
          HStack {
            Label(details?.statusLabel ?? (request.isDraft ? "草稿" : "最后记录为开放"),
              systemImage: details?.state.uppercased() == "MERGED" ? "checkmark.circle.fill"
                : "arrow.triangle.pullrequest")
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
          }.appFont(.caption).foregroundStyle(.secondary)
          Text("\(details?.headRefName ?? request.headRefName) → \(details?.baseRefName ?? request.baseRefName)")
            .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          if let details {
            if let decision = details.reviewDecision, !decision.isEmpty {
              LabeledContent("审查", value: reviewLabel(decision))
            }
            let checks = details.checkSummary
            if checks.passed + checks.failed + checks.pending > 0 {
              LabeledContent("检查", value:
                "\(checks.passed) 通过 · \(checks.failed) 失败 · \(checks.pending) 进行中")
            }
            if let mergeable = details.mergeable, mergeable.uppercased() == "CONFLICTING" {
              Label("存在合并冲突", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
            if let body = details.body, !body.isEmpty {
              Divider()
              MessageMarkdownView(source: body, partPrefix: "pull-request") { url in
                openExternal(url)
              }
            }
          }
          if let snapshot = state.snapshot, snapshot.showsActions {
            TaskPullRequestActionsView(state: state, request: request, writable: writable,
              apply: apply)
          }
          if let error = state.error {
            Label(error, systemImage: "exclamationmark.circle")
              .appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          if let notice = state.notice {
            Text(notice).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          HStack {
            Button("刷新状态") { Task { await refresh() } }
              .disabled(state.loading || state.busy(for: request))
            Spacer()
            Menu {
              Button("复制链接") {
                guard let url = request.validatedURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
              }
              Button("在浏览器中打开") {
                if let url = request.validatedURL { openExternal(url) }
              }
            } label: { Image(systemName: "ellipsis") }
              .menuStyle(.borderlessButton)
              .accessibilityLabel("PR 更多操作")
          }
        }
        .appFont(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
      }
    }
    .frame(width: compact ? 316 : nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial)
    .task(id: taskID + root.path + request.url) { state.cancel(); await refresh(); consumeMergeRequest() }
    .onChange(of: presentations?.token(tabID)) { _, _ in consumeMergeRequest() }
    .onChange(of: state.snapshot) { _, _ in consumeMergeRequest() }
    .onChange(of: root) { _, _ in presentations?.clear(tabID) }
    .onDisappear { presentations?.clear(tabID); state.cancel() }
    .sheet(isPresented: $state.showingMergeConfirmation) {
      TaskPullRequestMergeConfirmation(state: state, request: request, writable: writable,
        confirm: { apply(.merge(state.selectedMethod)) })
    }
  }

  private func refresh() async {
    await state.refresh(request, at: root, preferred: store.library.gitPreferences.pullRequestMergeMethod,
      valid: { valid }, updated: onRefresh)
  }

  private func consumeMergeRequest() {
    guard let presentations, let token = presentations.token(tabID), !state.loading,
      let snapshot = state.snapshot else { return }
    presentations.consume(tabID, token: token)
    guard valid, snapshot.isAuthor, !snapshot.details.isDraft,
      snapshot.details.state.uppercased() != "MERGED" else { return }
    state.showingMergeConfirmation = true
  }

  private func apply(_ action: GitHubPRMergeAction) {
    state.start(action, request: request, at: root, valid: { valid }, writable: { writable },
      updated: onRefresh, saveFallback: {
        var preferences = store.library.gitPreferences
        preferences.pullRequestMergeMethod = .squash
        return store.saveGitPreferences(preferences)
      })
  }

  private func reviewLabel(_ decision: String) -> String {
    switch decision.uppercased() {
    case "APPROVED": "已批准"
    case "CHANGES_REQUESTED": "要求修改"
    case "REVIEW_REQUIRED": "等待审查"
    default: decision
    }
  }
}
