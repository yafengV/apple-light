import SwiftUI

struct TaskPullRequestActivityView: View {
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let retry: () -> Void
  let confirm: () -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  var fixes: PullRequestCommentFixControls? = nil
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
            if snapshot.isActivityPartial {
              Text("部分审查详情未能载入。").appFont(size: 14).foregroundStyle(.secondary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if snapshot.activity.isEmpty { Text("暂无活动").foregroundStyle(.secondary) }
            ForEach(snapshot.activity) { item in
              switch item {
              case .comment(let comment):
                TaskPullRequestCommentView(comment: comment, thread: nil, state: state,
                  enabled: enabled, writable: writable, mentionRequest: mentionRequest, open: open, submit: submit)
              case .thread(let thread):
                TaskPullRequestThreadView(thread: thread, state: state, enabled: enabled, writable: writable, mentionRequest: mentionRequest, open: open, submit: submit, fixes: fixes)
              case .event(let event):
                TaskPullRequestActivityEventView(event: event)
              case .commitGroup(let group):
                TaskPullRequestCommitGroupView(group: group, open: open)
              }
            }
          }
        }.padding(.top, 8)
      } label: {
        HStack {
          Text("Activity\(state.snapshot.map { " · \($0.activity.count)" } ?? "")").appFont(.headline)
          Spacer()
          if let fixes {
            let threads = state.snapshot?.threads.filter { PullRequestCommentAttachment(thread: $0).isValid } ?? []
            let ids = Set(threads.map(\.id)), attached = !ids.isEmpty && ids.isSubset(of: fixes.ids)
            if !threads.isEmpty {
              Button(attached ? "Remove" : "Fix all") { if attached { fixes.remove(ids) } else { fixes.add(threads) } }
                .buttonStyle(.plain).disabled(fixes.busy || !attached && fixes.disabledReason != nil)
                .help(attached ? "移除评论附件" : fixes.disabledReason ?? "附加所有待处理审查线程")
            }
          }
        }
      }
      .id("pull-request-activity")
      if let error = state.message(for: .activity) {
        Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
        Button("重新读取活动", action: retry).disabled(state.busy || state.refreshing)
      }
      if state.uncertain != nil { Button("重新读取操作结果", action: confirm).disabled(state.busy) }
      if let notice = state.notice { Text(notice).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      if state.snapshot != nil {
        Divider()
        TaskPullRequestCommentComposer(text: Binding(get: { state.commentBody }, set: {
          state.commentBody = $0; state.clearError(.general)
        }), label: "发表评论", focus: nil, enabled: enabled, busy: state.pendingOwner == .general, cancel: nil,
          inputEnabled: state.canEdit(.general, writable: writable), error: state.message(for: .general), mentionRequest: mentionRequest) {
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
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  let fixes: PullRequestCommentFixControls?
  @State private var expanded: Bool
  init(thread: GitHubPRReviewThread, state: GitHubPRDiscussionState, enabled: Bool, writable: Bool,
    mentionRequest: GitHubPRMentionRequest?,
    open: @escaping (URL) -> Void, submit: @escaping (GitHubPRDiscussionAction, String?) -> Void, fixes: PullRequestCommentFixControls? = nil) {
    self.fixes = fixes
    self.thread = thread; self.state = state; self.enabled = enabled; self.writable = writable; self.mentionRequest = mentionRequest; self.open = open; self.submit = submit
    _expanded = State(initialValue: !thread.isResolved && thread.comments.first?.authorType == "User")
  }
  private var hasDraft: Bool { thread.comments.contains { state.drafts[$0.id] != nil } }
  private var attached: PullRequestCommentAttachment? { fixes?.attachments.first { $0.id == thread.id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DisclosureGroup(isExpanded: Binding(get: { expanded || hasDraft }, set: { if !hasDraft { expanded = $0 } })) {
        VStack(alignment: .leading, spacing: 10) {
          if !thread.diffHunk.isEmpty {
            ScrollView(.horizontal) { Text(thread.diffHunk).appFont(.caption).monospaced().textSelection(.enabled) }
              .frame(maxHeight: 140).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
          }
          ForEach(thread.comments) { comment in
            TaskPullRequestCommentView(comment: comment, thread: thread, state: state,
              enabled: enabled, writable: writable, mentionRequest: mentionRequest, open: open, submit: submit,
              fixing: attached != nil)
          }
          if attached == nil {
            HStack {
              if let first = thread.comments.first, thread.canReply {
                Button("回复") { state.beginReply(first, thread: thread, quote: false) }
                  .disabled(!state.canEdit(.draft(first.id), writable: writable))
              }
              Spacer()
              if thread.isResolved ? thread.canUnresolve : thread.canResolve {
                Button(thread.isResolved ? "重新打开线程" : "解决线程") {
                  submit(.resolve(thread: thread.id, resolved: !thread.isResolved), nil)
                }.disabled(!enabled)
              }
            }
          }
          if let error = state.message(for: .thread(thread.id)) { Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled) }
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
      if let fixes {
        if let attached {
          PullRequestCommentGuidanceView(attachment: attached,
            save: { fixes.guidance(thread.id, $0) }, remove: { fixes.remove([thread.id]) })
        } else if PullRequestCommentAttachment(thread: thread).isValid {
          HStack { Spacer(); Button("Fix") { fixes.add([thread]) }
            .buttonStyle(.plain).disabled(fixes.busy || fixes.disabledReason != nil)
            .help(fixes.disabledReason ?? "附加此审查线程") }
        }
      }
    }
  }
}

struct TaskPullRequestCommentView: View {
  let comment: GitHubPRComment
  let thread: GitHubPRReviewThread?
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  let fixing: Bool
  @State private var expanded: Bool
  init(comment: GitHubPRComment, thread: GitHubPRReviewThread?, state: GitHubPRDiscussionState, enabled: Bool, writable: Bool, mentionRequest: GitHubPRMentionRequest?,
    open: @escaping (URL) -> Void, submit: @escaping (GitHubPRDiscussionAction, String?) -> Void,
    fixing: Bool = false) {
    self.fixing = fixing
    self.comment = comment; self.thread = thread; self.state = state; self.enabled = enabled; self.writable = writable; self.mentionRequest = mentionRequest; self.open = open; self.submit = submit
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
        if !fixing {
          Menu {
            if comment.canUpdate { Button("编辑") { state.beginEdit(comment) } }
            if thread == nil || thread?.canReply == true {
              Button("引用回复") { state.beginReply(comment, thread: thread, quote: true) }
            }
            if comment.canDelete { Button("删除", role: .destructive) { state.deleteTarget = comment; state.clearError(.delete(comment.id)) } }
          } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().disabled(!state.canEdit(.draft(comment.id), writable: writable) || draft != nil)
            .accessibilityLabel("评论操作")
        }
      }
      TaskPullRequestActivityDateView(value: comment.activityDate)
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
      state.drafts[comment.id]?.text = $0; state.clearError(.draft(comment.id))
    }), label: label, focus: draft.focus, enabled: enabled, busy: state.pendingOwner == .draft(comment.id),
      cancel: { state.cancelDraft(comment.id) }, inputEnabled: state.canEdit(.draft(comment.id), writable: writable),
      error: state.message(for: .draft(comment.id)), mentionRequest: mentionRequest) {
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

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
