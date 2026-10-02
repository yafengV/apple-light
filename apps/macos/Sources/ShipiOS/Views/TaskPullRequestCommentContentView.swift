import SwiftUI

struct TaskPullRequestCommentContentView: View {
  let comment: GitHubPRComment
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  @State private var expanded = false
  @State private var contentHeight: CGFloat = 0
  private let collapsedHeight: CGFloat = 60
  private var draft: GitHubPRCommentDraft? { state.drafts[comment.id] }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let draft, case .edit = draft.target { composer(draft, label: "保存更改") }
      else {
        MessageMarkdownView(source: comment.body.trimmingCharacters(in: .whitespacesAndNewlines),
          partPrefix: "pr-comment-" + comment.id, openLink: open)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: PullRequestCommentContentHeight.self,
                value: proxy.size.height)
            }
          }
          .frame(height: contentHeight > collapsedHeight + 1 && !expanded ? collapsedHeight : nil,
            alignment: .top)
          .clipped()
        if contentHeight > collapsedHeight + 1 {
          Button {
            expanded.toggle()
          } label: {
            HStack(spacing: 5) {
              Text(expanded ? "收起" : "展开更多")
              Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
            }.appFont(.caption).foregroundStyle(.secondary)
          }.buttonStyle(.plain)
            .accessibilityLabel(expanded ? "收起评论" : "展开完整评论")
            .accessibilityValue(expanded ? "已展开" : "已收起")
        }
      }
      if let draft, case .reply = draft.target { composer(draft, label: "发布回复") }
    }
    .onPreferenceChange(PullRequestCommentContentHeight.self) { contentHeight = $0 }
    .onChange(of: comment.body) { _, _ in expanded = false }
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
