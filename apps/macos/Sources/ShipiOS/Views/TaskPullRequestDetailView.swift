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
  var focusComposer: (() -> Void)? = nil
  var compact = true
  var presentations: PullRequestTabPresentations? = nil
  var tabID: String = ""

  @State private var state = GitHubPRDetailState()
  @State private var editor = GitHubPREditState()
  @State private var editorOwner = UUID()
  @State private var checks = GitHubPRChecksState()
  @State private var fixBranch: String?
  @State private var fixing = false
  @State private var fixError: String?
  private var details: GitHubPRDetails? { state.snapshot?.details }
  private var valid: Bool {
    !store.restoringLibrary && !store.shuttingDown
      && store.library.tasks.contains { $0.id == taskID && $0.project == root.path }
      && store.library.taskPullRequests[taskID]?.contains {
        $0.validatedURL == request.validatedURL && $0.number == request.number && $0.validatedURL != nil
      } == true
  }
  private var writable: Bool { valid && !store.library.gitPreferences.readOnlyReview }

  private var checksRequest: GitHubPRChecksRequest? {
    guard valid, let head = state.snapshot?.headRevision else { return nil }
    let current = details?.recorded(updating: request, at: request.checkedAt ?? .distantPast) ?? request
    return .init(taskID: taskID, root: root, pullRequest: current, headRevision: head)
  }

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
          TaskPullRequestTitleView(editor: editor, snapshot: state.snapshot, request: request,
            writable: writable, save: { save(.title) }, open: openExternal)
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
            LabeledContent("检查", value: checks.loading ? "读取中…"
              : checks.error != nil ? "无法读取检查" : checks.snapshot?.statusLabel ?? "等待检查详情")
            if let mergeable = details.mergeable, mergeable.uppercased() == "CONFLICTING" {
              Label("存在合并冲突", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
          }
          Divider()
          TaskPullRequestDescriptionView(editor: editor, snapshot: state.snapshot, request: request,
            writable: writable, loading: state.loading, save: { save(.body) },
            generate: generateDescription, open: openExternal)
          if state.snapshot != nil {
            Divider()
            TaskPullRequestChecksView(state: checks, openLink: openExternal,
              retry: { Task { await retryChecks() } },
              attached: attachedKeys, fixDisabledReason: fixReason, fixing: fixing,
              fix: attachChecks, remove: removeChecks)
            if let fixError { Text(fixError).foregroundStyle(.orange).appFont(.caption).textSelection(.enabled) }
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
    .task(id: taskID + root.path + request.url) {
      editor.detach(editorOwner)
      editor = GitHubPREditRegistry.shared.state(dataRoot: store.dataRoot, root: root, request: request)
      editor.attach(editorOwner)
      state.trackEditor(editor)
      state.cancel(); await refresh(); consumeMergeRequest()
    }
    .onChange(of: editor.revision) { _, _ in
      guard valid, let snapshot = editor.snapshot, snapshot.details.url == request.url else { return }
      guard state.acceptEditorChanges(editor) != nil else { return }
      onRefresh(snapshot.details.recorded(updating: request))
    }
    .task(id: checksRequest) {
      await loadChecks()
      while !Task.isCancelled, checksRequest != nil,
        let seconds = checks.error != nil ? 60 : checks.snapshot?.refreshSeconds {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        guard valid, !Task.isCancelled else { return }
        if NSApp.isActive { await loadChecks() }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      if valid, !checks.loading { Task { await retryChecks() } }
    }
    .onChange(of: checks.snapshot?.pullRequestState) { _, latest in
      if let latest, valid, !state.loading, latest.uppercased() != details?.state.uppercased() {
        // Run outside the checks task: refreshing PR metadata changes its request and cancels that task.
        Task { await refresh() }
      }
    }
    .onChange(of: presentations?.token(tabID)) { _, _ in consumeMergeRequest() }
    .onChange(of: state.snapshot) { _, _ in consumeMergeRequest() }
    .onChange(of: root) { _, _ in presentations?.clear(tabID) }
    .onDisappear { presentations?.clear(tabID); editor.detach(editorOwner); state.cancel(); checks.cancel() }
    .sheet(isPresented: $state.showingMergeConfirmation) {
      TaskPullRequestMergeConfirmation(state: state, request: request, writable: writable,
        confirm: { apply(.merge(state.selectedMethod)) })
    }
  }

  private func refresh() async {
    await state.refresh(request, at: root, preferred: store.library.gitPreferences.pullRequestMergeMethod,
      valid: { valid }, updated: onRefresh)
  }

  private func save(_ field: GitHubPREditField) {
    editor.save(field, snapshot: state.snapshot, request: request, at: root,
      valid: { valid }, writable: { writable }, updated: onRefresh)
  }

  private func generateDescription() {
    guard let snapshot = state.snapshot, writable else { return }
    do {
      let configuration = store.modelConfiguration
      try configuration.validateEndpoint()
      let key = try ModelKeychain.read(account: configuration.credentialAccount)
      let generate = GitTextGenerator.make(config: configuration, key: key, repository: root,
        dataRoot: store.dataRoot, executable: store.executable)
      editor.generate(snapshot: snapshot, request: request,
        instructions: store.library.gitPreferences.pullRequestInstructions, at: root,
        valid: { valid }, writable: { writable }, generate: generate, updated: onRefresh)
    } catch {
      editor.reportGenerationError(error.localizedDescription, snapshot: snapshot,
        request: request, writable: writable)
    }
  }

  private func retryChecks() async {
    if checks.requiresPullRequestRefresh { await refresh() } else { await loadChecks() }
  }

  private func loadChecks() async {
    let request = checksRequest
    let branch = try? await WorkspaceStore.pullRequestCheckBranch(at: root)
    guard valid, checksRequest == request, !Task.isCancelled else { return }
    fixBranch = branch
    await checks.load(request, valid: { valid && checksRequest == request })
  }

  private var attachedKeys: Set<String> {
    guard let request = checksRequest, let draft = store.library.pullRequestCheckDrafts[taskID],
      draft.matches(request) else { return [] }
    return draft.keys
  }
  private var fixReason: String? {
    guard let request = checksRequest else { return "等待 PR 状态。" }
    return store.pullRequestCheckFixReason(request, state: checks.snapshot?.pullRequestState, branch: fixBranch)
  }
  private func attachChecks(_ selected: [GitHubPRCheck]) {
    guard !fixing, let request = checksRequest, let snapshot = checks.snapshot else { return }
    fixing = true; fixError = nil
    Task {
      defer { fixing = false }
      do {
        if try await store.attachPullRequestChecks(selected, request: request, snapshot: snapshot,
          valid: { valid && checksRequest == request && checks.snapshot == snapshot }) {
          focusComposer?()
        }
      } catch {
        if valid, checksRequest == request { fixError = error.localizedDescription }
      }
    }
  }
  private func removeChecks(_ selected: [GitHubPRCheck]) {
    guard let request = checksRequest else { return }
    _ = store.removePullRequestChecks(Set(selected.map(\.attachmentKey)), taskID: taskID, request: request)
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
