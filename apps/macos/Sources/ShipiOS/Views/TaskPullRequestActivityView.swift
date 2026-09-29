import SwiftUI

struct TaskPullRequestActivityView: View {
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let open: (URL) -> Void
  let retry: () -> Void
  let confirm: () -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  @State private var expanded = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
        if value || state.drafts.isEmpty { expanded = value }
      })) {
        VStack(alignment: .leading, spacing: 12) {
          if state.loading { ProgressView("读取活动…").controlSize(.small) }
          else if state.readError != nil { Text("无法读取活动，请重试。").foregroundStyle(.secondary) }
          else if let snapshot = state.snapshot {
            if !snapshot.omittedTypes.isEmpty {
              Text("部分 GitHub 活动尚未显示：" + snapshot.omittedTypes.sorted().joined(separator: "、"))
                .appFont(.caption).foregroundStyle(.secondary)
            }
            if snapshot.activity.isEmpty { Text("暂无活动").foregroundStyle(.secondary) }
            ForEach(snapshot.activity) { item in
              switch item {
              case .comment(let comment):
                TaskPullRequestCommentView(comment: comment, thread: nil, state: state,
                  enabled: enabled, open: open, submit: submit)
              case .thread(let thread):
                TaskPullRequestThreadView(thread: thread, state: state, enabled: enabled, open: open, submit: submit)
              case .event(let event):
                HStack(alignment: .top) {
                  Image(systemName: event.kind == "PullRequestCommit" ? "point.3.connected.trianglepath.dotted" : "circle.fill")
                    .foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(event.author + " · " + event.text).textSelection(.enabled)
                    if event.kind == "PullRequestCommit" { Text(String(event.id.prefix(8))).appFont(.caption).monospaced() }
                    Text(event.createdAt).appFont(.caption).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                  if let raw = event.url, let url = TaskPullRequestCommentView.link(raw) {
                    Button { open(url) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("打开提交")
                  }
                }.appFont(.callout)
              }
            }
          }
        }.padding(.top, 8)
      } label: {
        Text("Activity\(state.snapshot.map { " · \($0.activity.count)" } ?? "")").appFont(.headline)
      }
      .id("pull-request-activity")
      if let error = state.error {
        Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
        if state.uncertain != nil { Button("重新读取操作结果", action: confirm).disabled(state.busy) }
        else { Button("重新读取活动", action: retry).disabled(state.busy || state.refreshing) }
      }
      if let notice = state.notice { Text(notice).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      if state.snapshot != nil {
        Divider()
        TaskPullRequestCommentComposer(text: Binding(get: { state.commentBody }, set: {
          state.commentBody = $0; state.clearError()
        }), label: "发表评论", focus: nil, enabled: enabled, busy: state.busy, cancel: nil) {
          submit(.post(body: state.commentBody, thread: nil), nil)
        }
      }
    }
    .onChange(of: state.drafts) { _, value in if !value.isEmpty { expanded = true } }
  }
}

private struct TaskPullRequestThreadView: View {
  let thread: GitHubPRReviewThread
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  @State private var expanded: Bool
  init(thread: GitHubPRReviewThread, state: GitHubPRDiscussionState, enabled: Bool,
    open: @escaping (URL) -> Void, submit: @escaping (GitHubPRDiscussionAction, String?) -> Void) {
    self.thread = thread; self.state = state; self.enabled = enabled; self.open = open; self.submit = submit
    _expanded = State(initialValue: !thread.isResolved && thread.comments.first?.authorType == "User")
  }
  private var hasDraft: Bool { thread.comments.contains { state.drafts[$0.id] != nil } }
  var body: some View {
    DisclosureGroup(isExpanded: Binding(get: { expanded || hasDraft }, set: { if !hasDraft { expanded = $0 } })) {
      VStack(alignment: .leading, spacing: 10) {
        if !thread.diffHunk.isEmpty {
          ScrollView(.horizontal) { Text(thread.diffHunk).appFont(.caption).monospaced().textSelection(.enabled) }
            .frame(maxHeight: 140).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        ForEach(thread.comments) { comment in
          TaskPullRequestCommentView(comment: comment, thread: thread, state: state,
            enabled: enabled, open: open, submit: submit)
        }
        HStack {
          if let first = thread.comments.first, thread.canReply {
            Button("回复") { state.beginReply(first, thread: thread, quote: false) }.disabled(!enabled)
          }
          Spacer()
          if thread.isResolved ? thread.canUnresolve : thread.canResolve {
            Button(thread.isResolved ? "重新打开线程" : "解决线程") {
              submit(.resolve(thread: thread.id, resolved: !thread.isResolved), nil)
            }.disabled(!enabled)
          }
        }
      }.padding(.top, 8)
    } label: {
      HStack {
        Text(thread.path + (thread.line ?? thread.originalLine).map { ":\($0)" }.orEmpty).lineLimit(2)
        Spacer()
        if thread.isResolved { Text("已解决").foregroundStyle(.secondary) }
        else if thread.isOutdated { Text("已过时").foregroundStyle(.secondary) }
      }.appFont(.caption)
    }
    .onChange(of: thread.isResolved) { _, resolved in if resolved && !hasDraft { expanded = false } }
  }
}

struct TaskPullRequestCommentView: View {
  let comment: GitHubPRComment
  let thread: GitHubPRReviewThread?
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  @State private var expanded: Bool
  init(comment: GitHubPRComment, thread: GitHubPRReviewThread?, state: GitHubPRDiscussionState, enabled: Bool,
    open: @escaping (URL) -> Void, submit: @escaping (GitHubPRDiscussionAction, String?) -> Void) {
    self.comment = comment; self.thread = thread; self.state = state; self.enabled = enabled; self.open = open; self.submit = submit
    _expanded = State(initialValue: comment.authorType == "User")
  }
  private var draft: GitHubPRCommentDraft? { state.drafts[comment.id] }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Button { if draft == nil { expanded.toggle() } } label: {
          Image(systemName: expanded || draft != nil ? "chevron.down" : "chevron.right")
        }.buttonStyle(.plain).accessibilityLabel("展开或收起评论")
        authorAvatar
        Text(comment.author).appFont(.callout).bold()
        if let status = comment.reviewState { Text(Self.reviewLabel(status)).appFont(.caption).foregroundStyle(.secondary) }
        Spacer(minLength: 0)
        if let raw = comment.url, let url = Self.link(raw) {
          Button { open(url) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).help("在 GitHub 打开评论")
        }
        Menu {
          if comment.canUpdate { Button("编辑") { state.beginEdit(comment) } }
          if thread == nil || thread?.canReply == true {
            Button("引用回复") { state.beginReply(comment, thread: thread, quote: true) }
          }
          if comment.canDelete { Button("删除", role: .destructive) { state.deleteTarget = comment; state.clearError() } }
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton).fixedSize().disabled(!enabled || draft != nil)
          .accessibilityLabel("评论操作")
      }
      Text(comment.createdAt).appFont(.caption).foregroundStyle(.secondary)
      if let draft, case .edit = draft.target {
        composer(draft, label: "保存更改")
      } else if expanded || draft != nil {
        if comment.body.isEmpty { Text("未附审查说明").foregroundStyle(.secondary).appFont(.caption) }
        else { MessageMarkdownView(source: comment.body, partPrefix: "pr-comment-" + comment.id, openLink: open) }
      }
      if let draft, case .reply = draft.target { composer(draft, label: "发布回复") }
    }.padding(10).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
  }
  private func composer(_ draft: GitHubPRCommentDraft, label: String) -> some View {
    TaskPullRequestCommentComposer(text: Binding(get: { state.drafts[comment.id]?.text ?? "" }, set: {
      state.drafts[comment.id]?.text = $0; state.clearError()
    }), label: label, focus: draft.focus, enabled: enabled, busy: state.busy,
      cancel: { state.cancelDraft(comment.id) }) {
        if let action = state.draftAction(comment.id) { submit(action, comment.id) }
      }
  }
  private var authorAvatar: some View {
    AsyncImage(url: comment.avatarURL.flatMap(URL.init(string:))) { phase in
      if case .success(let image) = phase { image.resizable().scaledToFill() }
      else { Text(String(comment.author.prefix(1)).uppercased()).appFont(.caption).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
    }.frame(width: 22, height: 22).clipShape(Circle()).accessibilityHidden(true)
  }
  static func link(_ raw: String) -> URL? {
    guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host?.lowercased() == "github.com",
      parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
    return parts.url
  }
  static func reviewLabel(_ value: String) -> String {
    switch value { case "APPROVED": "已批准"; case "CHANGES_REQUESTED": "要求修改"; case "COMMENTED": "已审查"; case "DISMISSED": "已撤销审查"; default: value }
  }
}

struct TaskPullRequestCommentComposer: View {
  @Binding var text: String
  let label: String
  let focus: UUID?
  let enabled: Bool
  let busy: Bool
  let cancel: (() -> Void)?
  let submit: () -> Void
  private var canSubmit: Bool { enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      PullRequestTextEditor(text: $text, field: .body, focus: focus,
        submit: { if canSubmit { submit() } }, cancel: {}, accessibilityName: label)
        .frame(height: 92).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .disabled(!enabled)
      HStack {
        Spacer()
        if let cancel { Button("取消", action: cancel).disabled(!enabled) }
        Button(action: submit) {
          HStack { if busy { ProgressView().controlSize(.small) }; Text(label) }
        }.disabled(!canSubmit)
      }
    }
  }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
