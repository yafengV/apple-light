import SwiftUI

struct PullRequestInlineCommentControls {
  let code: GitHubPRCodeSnapshot
  let discussion: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let submit: (GitHubPRDiscussionAction, String?) -> Void
}

struct TaskPullRequestInlineCommentView: View {
  let id: String
  let draft: GitHubPRCommentDraft
  let controls: PullRequestInlineCommentControls
  let cancel: () -> Void
  private var owner: GitHubPRDiscussionErrorOwner { .draft(id) }
  private var anchor: GitHubPRInlineAnchor? { if case .inline(_, let anchor) = draft.target { return anchor }; return nil }
  private var matches: Bool { anchor.map { $0.matches(controls.code) && !controls.discussion.isCodeStale($0.identity) } == true }
  private var editable: Bool { controls.discussion.canEdit(owner, writable: controls.writable) }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(controls.discussion.snapshot?.viewer ?? "你").appFont(size: 13, weight: .medium)
        Spacer()
        if let anchor { Text(anchor.position.label).appFont(size: 11).foregroundStyle(.secondary) }
      }
      if !matches {
        Text("PR 代码版本已变化。草稿保留在原位置，请复制正文后重新选择代码行。")
          .appFont(size: 12).foregroundStyle(.secondary)
      }
      TaskPullRequestCommentComposer(text: Binding(
        get: { controls.discussion.drafts[id]?.text ?? draft.text },
        set: { if editable { controls.discussion.drafts[id]?.text = $0 } }),
        label: "发布代码评论", focus: draft.focus, enabled: controls.enabled && matches,
        busy: controls.discussion.pendingOwner == owner, cancel: cancel, inlineCode: true,
        inputEnabled: editable, error: controls.discussion.message(for: owner), mentionRequest: controls.mentionRequest,
        submit: { if matches, let action = controls.discussion.draftAction(id) { controls.submit(action, id) } })
    }.padding(10).background(.background, in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      .accessibilityIdentifier("pull-request-inline-comment-" + id)
  }
}
