import AppKit
import SwiftUI

struct TaskPullRequestCommentView: View {
  let card: GitHubPRCommentCard
  let collapse: GitHubPRCommentCollapseState
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  var fixes: PullRequestCommentFixControls? = nil
  var openFile: ((GitHubPRCommentPosition) -> Void)? = nil
  var showsCodeContext = true
  @State private var hovered = false
  @FocusState private var focusedControl: String?
  @Environment(\.appAppearance) private var appearance
  private var comment: GitHubPRComment { card.comment }
  private var thread: GitHubPRReviewThread? { card.thread }
  private var collapsed: Bool { collapse.isCollapsed(card, drafts: state.drafts) }
  private var attached: PullRequestCommentAttachment? { fixes?.attachments.first { $0.id == thread?.id } }
  private var hasEditor: Bool {
    state.drafts.contains { id, draft in card.allIDs.contains(id) && { if case .edit = draft.target { return true }; return false }() }
  }
  private var hasReply: Bool {
    state.drafts.contains { id, draft in card.allIDs.contains(id) && { if case .reply = draft.target { return true }; return false }() }
  }
  private var actionsVisible: Bool { attached == nil && !hasEditor && !hasReply }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if let thread, showsCodeContext { fileLocation(thread) }
      if !collapsed {
        if let thread, showsCodeContext, !thread.diffHunk.isEmpty, thread.position != nil {
          TaskPullRequestThreadDiffView(thread: thread)
        }
        TaskPullRequestCommentContentView(comment: comment, state: state, enabled: enabled, writable: writable,
          mentionRequest: mentionRequest, open: open, submit: submit)
          .padding(.leading, 46).padding(.trailing, 12).padding(.top, 8).padding(.bottom, 10)
        ForEach(card.replies) { reply in replyView(reply) }
        footer
      }
    }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      .onHover { hovered = $0 }
      .accessibilityIdentifier("pr-comment-card-" + card.id)
  }
  private var header: some View {
    HStack(spacing: 8) {
      Button(action: toggle) {
        HStack(spacing: 10) {
          TaskPullRequestCommentAvatar(comment: comment)
          HStack(spacing: 6) {
            Text(comment.author).appFont(size: 16, weight: .medium).lineLimit(1)
            if thread?.isResolved == true { Text("已解决").appFont(size: 14).foregroundStyle(.secondary) }
            if !card.replies.isEmpty {
              Text((thread?.isResolved == true ? "· " : "") + "\(card.replies.count) 条回复")
                .appFont(size: 14).foregroundStyle(.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right").appFont(size: 10).foregroundStyle(.tertiary)
              .rotationEffect(.degrees(collapsed ? 0 : 90))
              .opacity(hovered || focusedControl != nil || hasEditor || hasReply ? 1 : 0)
              .animation(appearance.shouldReduceMotion ? nil : .easeInOut(duration: 0.15), value: collapsed)
          }
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).focused($focusedControl, equals: "header")
        .onKeyPress(.return) { toggle(); return .handled }
        .accessibilityLabel((collapsed ? "展开 " : "收起 ") + comment.author + " 的评论")
        .accessibilityValue(collapsed ? "已收起" : "已展开")
        .accessibilityHint("按住 Option 同时展开或收起本活动页的评论")
        .accessibilityIdentifier("pr-comment-toggle-" + card.id)
      if let raw = comment.url, let url = Self.link(raw) {
        Button { open(url) } label: { Image(systemName: "arrow.up.right") }
          .buttonStyle(.plain).focused($focusedControl, equals: "link")
          .onKeyPress(.return) { open(url); return .handled }
          .opacity(hovered || focusedControl != nil ? 1 : 0)
          .help("在 GitHub 查看评论").accessibilityLabel("在 GitHub 打开评论")
      }
      TaskPullRequestActivityDateView(value: comment.activityDate).onTapGesture(perform: toggle)
      if showsActions(comment) { actions(comment).focused($focusedControl, equals: "actions") }
    }.padding(.horizontal, 12).padding(.vertical, 10)
  }
  @ViewBuilder private func fileLocation(_ thread: GitHubPRReviewThread) -> some View {
    HStack(spacing: 8) {
      if collapsed {
        Button { collapse.expand(card) } label: { Text((thread.path as NSString).lastPathComponent).lineLimit(1) }
          .buttonStyle(.plain).focused($focusedControl, equals: "file")
          .onKeyPress(.return) { collapse.expand(card); return .handled }
          .accessibilityLabel("展开 " + thread.path + " 的评论")
      } else if let openFile, let position = thread.position, position.isValid {
        Button { openFile(position) } label: { Text((thread.path as NSString).lastPathComponent).lineLimit(1) }
          .buttonStyle(.plain).focused($focusedControl, equals: "file")
          .onKeyPress(.return) { openFile(position); return .handled }
          .accessibilityLabel("在 Code 中打开 " + thread.path)
          .accessibilityIdentifier("pr-comment-open-file-" + card.id)
      } else { Text((thread.path as NSString).lastPathComponent).lineLimit(1) }
      if let position = thread.position, collapsed || thread.diffHunk.isEmpty {
        Text(position.label).lineLimit(1)
      }
      Spacer(minLength: 0)
    }.appFont(size: 14).foregroundStyle(.tertiary).help(thread.path)
      .padding(.leading, 46).padding(.trailing, 12).padding(.bottom, collapsed ? 10 : 4)
  }
  private func replyView(_ reply: GitHubPRComment) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        TaskPullRequestCommentAvatar(comment: reply)
        Text(reply.author).appFont(size: 16, weight: .medium).lineLimit(1)
        TaskPullRequestActivityDateView(value: reply.createdAt)
        Spacer(minLength: 0)
        if showsActions(reply, isReply: true) { actions(reply, isReply: true).focused($focusedControl, equals: reply.id) }
      }.padding(.leading, 46).padding(.trailing, 12)
      TaskPullRequestCommentContentView(comment: reply, state: state, enabled: enabled, writable: writable,
        mentionRequest: mentionRequest, open: open, submit: submit)
        .padding(.leading, 80).padding(.trailing, 12)
    }.padding(.top, 6).padding(.bottom, 6)
  }
  @ViewBuilder private var footer: some View {
    if let thread {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          if let fixes {
            if let attached {
              PullRequestCommentGuidanceView(attachment: attached,
                save: { fixes.guidance(thread.id, $0) }, remove: { fixes.remove([thread.id]) })
            } else if PullRequestCommentAttachment(thread: thread).isValid {
              Button("Fix") { fixes.add([thread]) }.buttonStyle(.plain)
                .disabled(fixes.busy || fixes.disabledReason != nil)
                .help(fixes.disabledReason ?? "附加此审查线程")
                .focused($focusedControl, equals: "fix")
            }
          }
          if actionsVisible, thread.canReply {
            Button("回复") { collapse.expand(card); state.beginReply(comment, thread: thread, quote: false) }
              .buttonStyle(.plain).disabled(!state.canEdit(.draft(comment.id), writable: writable))
              .focused($focusedControl, equals: "reply")
          }
          Spacer(minLength: 0)
          if actionsVisible, thread.isResolved ? thread.canUnresolve : thread.canResolve {
            Button(thread.isResolved ? "重新打开线程" : "解决线程") {
              submit(.resolve(thread: thread.id, resolved: !thread.isResolved), nil)
            }.buttonStyle(.plain).disabled(!enabled).focused($focusedControl, equals: "resolve")
          }
        }
        if let error = state.message(for: .thread(thread.id)) {
          Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
      }.padding(.leading, 46).padding(.trailing, 12).padding(.bottom, 10)
    }
  }
  private func showsActions(_ target: GitHubPRComment, isReply: Bool = false) -> Bool {
    actionsVisible && (target.canUpdate || target.canDelete || (!isReply && (thread == nil || thread?.canReply == true)))
  }
  private func actions(_ target: GitHubPRComment, isReply: Bool = false) -> some View {
    PullRequestCommentActionMenu(options: PullRequestCommentMenuAction.options(target, thread: thread, isReply: isReply),
      enabled: state.canEdit(.draft(target.id), writable: writable)) { action in
        guard state.canEdit(.draft(target.id), writable: writable), let current = state.snapshot?.comment(target.id) else { return false }
        let currentThread = thread.flatMap { old in state.snapshot?.threads.first { $0.id == old.id } }
        if thread != nil, currentThread == nil { return false }
        guard PullRequestCommentMenuAction.options(current, thread: currentThread, isReply: isReply).contains(action) else { return false }
        switch action {
        case .edit: collapse.expand(card); state.beginEdit(current)
        case .quote: collapse.expand(card); state.beginReply(current, thread: currentThread, quote: true)
        case .delete: state.deleteTarget = current; state.clearError(.delete(current.id))
        }
        return true
      }.id(target.id)
  }
  private func toggle() {
    collapse.toggle(card, all: NSApp.currentEvent?.modifierFlags.contains(.option) == true,
      cards: state.snapshot?.commentCards ?? [card], drafts: state.drafts)
  }
  static func link(_ raw: String) -> URL? {
    guard let parts = URLComponents(string: raw), parts.scheme == "https", parts.host?.lowercased() == "github.com",
      parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
    return parts.url
  }
}
