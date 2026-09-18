import SwiftUI

struct ReviewCommentView: View {
  @Bindable var store: WorkspaceStore
  let comment: ReviewComment
  var showLocation = false
  var taskID: String?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showLocation {
        Text(comment.anchor.path + " · " + comment.anchor.location).appFont(.caption).textSelection(
          .enabled)
        Text(comment.anchor.scope).appFont(.caption2).foregroundStyle(.secondary)
      }
      if comment.editingText != nil {
        TextField(
          "填写行内反馈…",
          text: Binding(
            get: {
              store.reviewComments(taskID: taskID).first { $0.id == comment.id }?.editingText ?? ""
            },
            set: { store.updateReviewComment(comment.id, text: $0, taskID: taskID) }), axis: .vertical
        )
        .textFieldStyle(.roundedBorder).lineLimit(2...6).focused($focused)
        .accessibilityLabel("审查评论")
        .onKeyPress(.escape) {
          store.cancelReviewComment(comment.id, taskID: taskID)
          return .handled
        }
        HStack {
          Button("取消") { store.cancelReviewComment(comment.id, taskID: taskID) }
          Spacer()
          Button("保存评论") { store.saveReviewComment(comment.id, taskID: taskID) }
            .disabled(
              (comment.editingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.controlSize(.small)
          .onAppear { focused = true }
      } else {
        Text(comment.body).appFont(.callout).textSelection(.enabled)
        HStack {
          Button("编辑") { store.editReviewComment(comment.id, taskID: taskID) }
          Button("移除") { store.removeReviewComment(comment.id, taskID: taskID) }
        }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
      }
    }.padding(10).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct ComposerReviewComments: View {
  @Bindable var store: WorkspaceStore
  @State private var expanded = false
  var body: some View {
    if !store.reviewComments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          expanded.toggle()
        } label: {
          Label(
            "\(store.reviewComments.count) 条审查评论将随消息发送",
            systemImage: expanded ? "chevron.down" : "chevron.right")
        }.buttonStyle(.plain).appFont(.caption)
        if expanded {
          ScrollView {
            VStack(spacing: 8) {
              ForEach(store.reviewComments) {
                ReviewCommentView(store: store, comment: $0, showLocation: true)
              }
            }
          }.frame(maxHeight: 220)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
