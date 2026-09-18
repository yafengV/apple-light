import SwiftUI

struct ComposerBrowserComments: View {
  @Bindable var store: WorkspaceStore
  @State private var expanded = false

  var body: some View {
    BrowserCommentComposerSummary(
      store: store, comments: store.browserComments, expanded: $expanded)
  }
}

struct TaskWindowBrowserComments: View {
  @Bindable var store: WorkspaceStore
  let taskID: String
  @State private var expanded = false

  var body: some View {
    BrowserCommentComposerSummary(
      store: store, comments: store.browserComments(taskID: taskID), taskID: taskID,
      expanded: $expanded)
  }
}

private struct BrowserCommentComposerSummary: View {
  @Bindable var store: WorkspaceStore
  let comments: [BrowserComment]
  var taskID: String?
  @Binding var expanded: Bool

  var body: some View {
    if !comments.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          expanded.toggle()
        } label: {
          Label(
            "\(comments.count) 条浏览器评论将随消息发送",
            systemImage: expanded ? "chevron.down" : "chevron.right")
        }.buttonStyle(.plain).appFont(.caption)
        if expanded {
          ScrollView {
            VStack(spacing: 8) {
              ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                HStack(alignment: .top, spacing: 8) {
                  Text("\(index + 1)").appFont(.caption, weight: .semibold)
                    .foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(Color.accentColor, in: Circle())
                  VStack(alignment: .leading, spacing: 3) {
                    Text(comment.body).appFont(.callout).textSelection(.enabled)
                    Text(comment.reference.pageTitle.isEmpty
                      ? comment.reference.url : comment.reference.pageTitle)
                      .appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer(minLength: 4)
                  Button("移除") { store.removeBrowserComment(comment.id, taskID: taskID) }
                    .buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
              }
            }
          }.frame(maxHeight: 220)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
