import SwiftUI

struct PullRequestCommentFixControls {
  let attachments: [PullRequestCommentAttachment]
  let disabledReason: String?
  let busy: Bool
  let add: ([GitHubPRReviewThread]) -> Void
  let remove: (Set<String>) -> Void
  let guidance: (String, String) -> Void
  var ids: Set<String> { Set(attachments.map(\.id)) }
}

struct PullRequestCommentGuidanceView: View {
  let attachment: PullRequestCommentAttachment
  let save: (String) -> Void
  let remove: () -> Void
  @State private var text: String
  init(attachment: PullRequestCommentAttachment, save: @escaping (String) -> Void, remove: @escaping () -> Void) {
    self.attachment = attachment; self.save = save; self.remove = remove
    _text = State(initialValue: attachment.guidance)
  }
  private var changed: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != attachment.guidance }
  var body: some View {
    HStack(spacing: 8) {
      TextField("添加可选修复说明…", text: $text).textFieldStyle(.plain)
        .accessibilityLabel("可选修复说明")
        .onSubmit { if changed { save(text) } }
        .onKeyPress(.escape) { text = attachment.guidance; return .handled }
      Button(action: remove) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Remove")
        .accessibilityLabel("移除评论附件")
      Button { save(text) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain)
        .disabled(!changed).help("保存修复说明").accessibilityLabel("保存修复说明")
    }.padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
      .onChange(of: attachment.guidance) { _, value in text = value }
  }
}

struct PullRequestCommentComposerAttachments: View {
  let store: WorkspaceStore
  let taskID: String?
  @State private var expanded = false
  var body: some View {
    if let taskID, let draft = store.library.pullRequestCheckDrafts[taskID], !draft.comments.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Button { expanded.toggle() } label: {
            Label("PR #\(draft.pullRequest.number) · \(draft.comments.count) 条审查线程",
              systemImage: expanded ? "chevron.down" : "chevron.right")
          }.buttonStyle(.plain)
          Spacer()
          Button("Remove all") { _ = store.removePullRequestComments(Set(draft.comments.map(\.id)), taskID: taskID) }
            .buttonStyle(.plain)
        }
        if expanded {
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(draft.comments) { attachment in
                VStack(alignment: .leading, spacing: 6) {
                  Text(attachment.position.map { $0.path + " · " + $0.label } ?? attachment.thread.path)
                    .appFont(.caption).textSelection(.enabled)
                  Text(attachment.body).appFont(.caption).lineLimit(5).textSelection(.enabled)
                  PullRequestCommentGuidanceView(attachment: attachment,
                    save: { _ = store.setPullRequestCommentGuidance($0, id: attachment.id, taskID: taskID) },
                    remove: { _ = store.removePullRequestComments([attachment.id], taskID: taskID) })
                }
              }
            }
          }.frame(maxHeight: 220)
        }
      }.appFont(.caption).padding(8).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}
