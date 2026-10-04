import SwiftUI

struct TaskPullRequestCommentContentView: View {
  let comment: GitHubPRComment
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  var isReply = false
  var preventsTruncation = false
  var showsReplyComposer = true
  @State private var expanded = false
  @State private var contentHeight: CGFloat = 0
  @State private var markdownLayout = PRCommentMarkdownLayout()
  @Environment(\.appAppearance) private var appearance
  private var collapsedHeight: CGFloat { markdownLayout.previewHeight ?? contentHeight }
  private var truncates: Bool { !isReply && !preventsTruncation }
  // The reference hook checks the wrapper's inherited chat line height, while
  // CSS line-clamp clips the actual small Markdown lines. These differ for
  // paragraphs and headings, so six blocks can still offer an expansion button.
  private var canExpand: Bool {
    contentHeight.rounded() > ceil(CGFloat(appearance.uiSize) * 1.5 * 6) + 1
  }
  private var draft: GitHubPRCommentDraft? { state.drafts[comment.id] }
  private var commentBody: String { comment.displayBody }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let draft, case .edit = draft.target { composer(draft, label: "保存更改") }
      else {
        commentContent
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: PullRequestCommentContentHeight.self,
                value: proxy.size.height)
            }
          }
          .frame(height: truncates && canExpand && !expanded ? collapsedHeight : nil,
            alignment: .top)
          .clipped()
        if truncates && canExpand {
          Button {
            expanded.toggle()
          } label: {
            HStack(spacing: 4) {
              Text(expanded ? "收起" : "展开更多")
              Image(systemName: "chevron.down").font(Font(appearance.nativeFont(size: 12).withSize(12))).frame(width: 12, height: 12).rotationEffect(.degrees(expanded ? 180 : 0))
            }.font(Font(appearance.nativeFont(size: 14).withSize(14))).frame(minHeight: 20).foregroundStyle(.secondary)
          }.buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起评论" : "展开完整评论")
            .accessibilityValue(expanded ? "已展开" : "已收起")
        }
      }
      if showsReplyComposer, let draft, case .reply = draft.target { composer(draft, label: "发布回复") }
    }
    .onPreferenceChange(PullRequestCommentContentHeight.self) { contentHeight = $0 }
    .onChange(of: comment.body) { _, _ in expanded = false }
  }
  @ViewBuilder private var commentContent: some View {
    MessageMarkdownView(source: commentBody, partPrefix: "pr-comment-" + comment.id,
      githubMedia: true, compactPRComment: true, prCommentLayout: markdownLayout, openLink: open)
  }
  private func composer(_ draft: GitHubPRCommentDraft, label: String) -> some View {
    TaskPullRequestCommentComposer(text: Binding(get: { state.drafts[comment.id]?.text ?? "" }, set: {
      state.drafts[comment.id]?.text = $0; state.clearError(.draft(comment.id))
    }), label: label, focus: draft.focus, enabled: enabled, busy: state.pendingOwner == .draft(comment.id),
      cancel: { state.cancelDraft(comment.id) }, inputEnabled: state.canEdit(.draft(comment.id), writable: writable),
      error: state.message(for: .draft(comment.id)), mentionRequest: mentionRequest,
      kind: { if case .edit = draft.target { return .edit }; return .reply(author: comment.author) }()) {
        if let action = state.draftAction(comment.id) { submit(action, comment.id) }
      }
  }
}

private struct PullRequestCommentContentHeight: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TaskPullRequestCommentAvatar: View {
  let comment: GitHubPRComment
  var body: some View {
    AsyncImage(url: comment.avatarURL.flatMap(URL.init(string:))) { phase in
      if case .success(let image) = phase { image.resizable().scaledToFill() }
      else { Text(String(comment.author.prefix(1)).uppercased()).appFont(size: 12, weight: .semibold)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
    }.frame(width: 24, height: 24).clipShape(Circle()).accessibilityHidden(true)
  }
}
