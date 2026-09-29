import SwiftUI

struct TaskPullRequestReviewDialog: View {
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let submit: () -> Void
  let confirm: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("提交审查").appFont(.title2).bold()
      Text("审查将关联当前显示的头提交；提交前会再次核对 PR。")
        .appFont(.caption).foregroundStyle(.secondary)
      if let head = state.reviewHead { Text(String(head.prefix(12))).appFont(.caption).monospaced().textSelection(.enabled) }
      Picker("审查结果", selection: Binding(get: { state.reviewDecision }, set: {
        state.reviewDecision = $0; state.clearError()
      })) {
        ForEach(GitHubPRReviewDecision.allCases) { decision in Text(decision.label).tag(decision) }
      }.pickerStyle(.radioGroup).disabled(state.busy || state.uncertain != nil)
      PullRequestTextEditor(text: Binding(get: { state.reviewBody }, set: {
        state.reviewBody = $0; state.clearError()
      }), field: .body, focus: state.reviewFocus,
        submit: { if enabled && state.reviewDecision.accepts(state.reviewBody) { submit() } }, cancel: {},
        accessibilityName: "审查说明")
        .frame(height: 126).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .disabled(state.busy || state.uncertain != nil)
      if let error = state.error { Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      HStack {
        if state.busy { ProgressView().controlSize(.small) }
        if state.uncertain != nil { Button("重新读取操作结果", action: confirm).disabled(state.busy) }
        Spacer()
        Button("取消") { state.closeReview() }.disabled(state.busy).keyboardShortcut(.cancelAction)
        Button("提交审查", action: submit).disabled(!enabled || !state.reviewDecision.accepts(state.reviewBody))
      }
    }.padding(24).frame(width: 460).interactiveDismissDisabled(state.busy)
  }
}

struct TaskPullRequestDeleteCommentDialog: View {
  let comment: GitHubPRComment
  let state: GitHubPRDiscussionState
  let enabled: Bool
  let submit: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("删除评论").appFont(.title2).bold()
      Text("此操作会永久删除 GitHub 上的这条评论。")
      Text(comment.body).lineLimit(5).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let error = state.error { Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      HStack {
        if state.busy { ProgressView().controlSize(.small) }
        Spacer()
        Button("取消") { state.deleteTarget = nil; state.clearError() }.disabled(state.busy).keyboardShortcut(.cancelAction)
        Button("删除", role: .destructive, action: submit).disabled(!enabled)
      }
    }.padding(24).frame(width: 420).interactiveDismissDisabled(state.busy)
  }
}
