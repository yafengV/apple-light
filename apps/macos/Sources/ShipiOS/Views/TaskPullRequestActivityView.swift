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
  @State private var comments = GitHubPRCommentCollapseState()

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
                TaskPullRequestCommentView(card: .init(comment: comment, thread: nil), collapse: comments, state: state,
                  enabled: enabled, writable: writable, mentionRequest: mentionRequest, open: open, submit: submit)
              case .thread(let thread):
                if let root = thread.comments.first {
                  TaskPullRequestCommentView(card: .init(comment: root, thread: thread), collapse: comments, state: state,
                    enabled: enabled, writable: writable, mentionRequest: mentionRequest, open: open, submit: submit, fixes: fixes)
                }
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
    .onChange(of: state.snapshot?.commentCards, initial: true) { _, value in
      comments.sync(value ?? [], drafts: state.drafts)
    }
    .onChange(of: state.drafts) { _, value in
      if !value.isEmpty { expanded = true }
      comments.sync(state.snapshot?.commentCards ?? [], drafts: value)
    }
  }
}
