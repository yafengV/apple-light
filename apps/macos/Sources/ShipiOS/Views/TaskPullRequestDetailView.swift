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
  @State private var discussion = GitHubPRDiscussionState()
  @State private var code = GitHubPRCodeState()
  @FocusState private var focusedPRPage: GitHubPRCodeState.Page?
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

  private var codeRequest: GitHubPRCodeRequest? {
    guard valid, let head = state.snapshot?.headRevision else { return nil }
    return .init(taskID: taskID, root: root, pullRequest: request, head: head)
  }

  private var content: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        if compact { Button(action: back) { Image(systemName: "chevron.left") }
          .buttonStyle(.plain).help("返回摘要").accessibilityLabel("返回摘要")
        }
        Text("Pull request #\(request.number)").appFont(.headline).lineLimit(1)
        Spacer(minLength: 0)
        if !compact, discussion.snapshot?.canReview == true {
          Button("提交审查") { discussion.openReview() }
            .disabled(!discussion.canWrite(request, writable: writable))
        }
        Button(action: close) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help(compact ? "关闭摘要" : "关闭 PR").accessibilityLabel(compact ? "关闭摘要" : "关闭 PR")
      }.padding(.horizontal, 16).padding(.vertical, 13)
      Divider()
      if !compact {
        HStack(spacing: 4) {
          ForEach(GitHubPRCodeState.Page.allCases, id: \.rawValue) { page in
            Button(page == .summary ? "概览" : "Code") { code.page = page }
              .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
              .background(code.page == page ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
              .accessibilityValue(code.page == page ? "已选中" : "未选中")
              .accessibilityIdentifier("pull-request-page-" + page.rawValue)
              .focused($focusedPRPage, equals: page)
              .onKeyPress(.leftArrow) { selectPRPage(page == .summary ? .code : .summary); return .handled }
              .onKeyPress(.rightArrow) { selectPRPage(page == .summary ? .code : .summary); return .handled }
              .onKeyPress(.home) { selectPRPage(.summary); return .handled }
              .onKeyPress(.end) { selectPRPage(.code); return .handled }
          }
          Spacer()
        }.padding(.horizontal, 12).padding(.vertical, 4)
        Divider()
      }
      if !compact, code.page == .code {
        TaskPullRequestCodeView(state: code, discussion: discussion,
          enabled: discussion.canWrite(request, writable: writable), writable: writable,
          mentionRequest: discussion.snapshot.map { .init(pullRequest: request, root: root, viewer: $0.viewer) },
          open: openExternal, submit: applyDiscussion, retry: retryCode,
          retryComments: { Task { await loadDiscussion() } }, confirm: confirmDiscussion, metadataLoading: state.loading,
          metadataError: codeRequest == nil ? state.error : nil)
      } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          TaskPullRequestTitleView(editor: editor, snapshot: state.snapshot, request: request,
            writable: writable, save: { save(.title) }, open: openExternal)
          HStack {
            Label(details?.statusLabel ?? (request.isDraft ? "草稿" : "最后记录为开放"),
              systemImage: details?.state.uppercased() == "MERGED" ? "checkmark.circle.fill"
                : "arrow.triangle.pullrequest")
            Spacer()
            if compact, discussion.snapshot?.canReview == true {
              Button("提交审查") { discussion.openReview() }
                .disabled(!discussion.canWrite(request, writable: writable))
            }
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
          Divider()
          TaskPullRequestActivityView(state: discussion,
            enabled: discussion.canWrite(request, writable: writable), writable: writable,
            mentionRequest: discussion.snapshot.map { .init(pullRequest: request, root: root, viewer: $0.viewer) }, open: openExternal,
            retry: { Task { await loadDiscussion() } }, confirm: confirmDiscussion, submit: applyDiscussion,
            fixes: commentFixControls, openFile: compact ? nil : { code.open($0) })
          if let error = state.error {
            Label(error, systemImage: "exclamationmark.circle")
              .appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
          }
          if let notice = state.notice {
            Text(notice).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }
          HStack {
            Button("刷新状态") { Task { await refresh(); await loadDiscussion() } }
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
    }
  }

  private var editorContent: some View {
    content
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
  }

  private var discussionContent: some View {
    editorContent
    .task(id: taskID + root.path + request.url) {
      discussion.cancel(); discussion = GitHubPRDiscussionState()
      await loadDiscussion()
    }
    .onChange(of: GitHubPRDiscussionUpdates.shared.revision(dataRoot: store.dataRoot, request: request)) { _, _ in
      if valid, !discussion.busy { Task { await refresh(); await loadDiscussion() } }
    }
    .onChange(of: state.snapshot) { _, value in
      if let value, let current = discussion.snapshot,
        current.head != value.headRevision || current.state != value.details.state.uppercased() {
        Task { await loadDiscussion() }
      }
    }
  }

  var body: some View {
    discussionContent
    .task(id: code.page == .code && !compact ? codeRequest : nil) {
      guard code.page == .code, !compact else { return }
      let captured = codeRequest
      await code.load(captured, valid: { valid && captured == codeRequest })
    }
    .onChange(of: codeRequest) { _, _ in if code.page != .code { code.invalidate() } }
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
    .onDisappear { presentations?.clear(tabID); editor.detach(editorOwner); state.cancel(); checks.cancel(); discussion.cancel(); code.cancel() }
    .sheet(isPresented: $state.showingMergeConfirmation) {
      TaskPullRequestMergeConfirmation(state: state, request: request, writable: writable,
        confirm: { apply(.merge(state.selectedMethod)) })
    }
    .sheet(isPresented: $discussion.showingReview) {
      TaskPullRequestReviewDialog(state: discussion, enabled: discussion.canWrite(request, writable: writable),
        submit: { if let action = discussion.reviewAction { applyDiscussion(action, nil) } }, confirm: confirmDiscussion)
    }
    .sheet(item: $discussion.deleteTarget) { comment in
      TaskPullRequestDeleteCommentDialog(comment: comment, state: discussion,
        enabled: discussion.canWrite(request, writable: writable),
        submit: { applyDiscussion(.delete(id: comment.id, kind: comment.kind), nil) })
    }
  }

  private func refresh() async {
    await state.refresh(request, at: root, preferred: store.library.gitPreferences.pullRequestMergeMethod,
      valid: { valid }, updated: onRefresh)
  }

  private func loadDiscussion() async {
    await discussion.load(request, at: root, valid: { valid })
  }
  private func retryCode() {
    Task {
      await refresh()
      guard let captured = codeRequest else { return }
      await code.refresh(captured, valid: { valid && captured == codeRequest })
    }
  }
  private func selectPRPage(_ page: GitHubPRCodeState.Page) {
    code.page = page; focusedPRPage = page
  }
  private func applyDiscussion(_ action: GitHubPRDiscussionAction, _ draftID: String?) {
    discussion.start(action, request: request, at: root, valid: { valid }, writable: { writable }, draftID: draftID,
      changed: {
        if case .resolve(let id, true) = action, let scope = checksRequest {
          _ = store.removePullRequestComments([id], taskID: taskID, request: scope)
        }
        discussionChanged()
      })
  }
  private func confirmDiscussion() {
    discussion.confirm(request: request, at: root, valid: { valid },
      changed: discussionChanged)
  }
  private func discussionChanged() {
    GitHubPRDiscussionUpdates.shared.publish(dataRoot: store.dataRoot, request: request)
    Task { await refresh(); await loadDiscussion() }
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
  private var commentFixControls: PullRequestCommentFixControls {
    let attached = checksRequest.flatMap { scope in
      store.library.pullRequestCheckDrafts[taskID].flatMap { $0.matches(scope) ? $0.comments : nil }
    } ?? []
    let reason = discussion.readError != nil || discussion.snapshot?.head != checksRequest?.headRevision
      ? "请先刷新 PR 评论与头提交。" : fixReason
    return .init(attachments: attached, disabledReason: reason, busy: fixing,
      add: attachComments, remove: { ids in
        guard let scope = checksRequest else { return }
        _ = store.removePullRequestComments(ids, taskID: taskID, request: scope)
      }, guidance: { id, text in _ = store.setPullRequestCommentGuidance(text, id: id, taskID: taskID) })
  }
  private func attachComments(_ selected: [GitHubPRReviewThread]) {
    guard !fixing, let scope = checksRequest, let snapshot = discussion.snapshot else { return }
    fixing = true; fixError = nil
    Task {
      defer { fixing = false }
      do {
        _ = try await store.attachPullRequestComments(selected, request: scope, snapshot: snapshot,
          valid: { valid && checksRequest == scope && discussion.snapshot == snapshot })
      } catch { if valid, checksRequest == scope { fixError = error.localizedDescription } }
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
