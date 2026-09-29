import SwiftUI

struct PullRequestCheckComposerAttachments: View {
  let store: WorkspaceStore
  let taskID: String?
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      PullRequestCommentComposerAttachments(store: store, taskID: taskID)
      if let taskID, let draft = store.library.pullRequestCheckDrafts[taskID], !draft.checks.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Button { expanded.toggle() } label: {
              Label("PR #\(draft.pullRequest.number) · \(draft.checks.count) 个失败检查",
                systemImage: expanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.plain)
            Spacer()
            Button("Remove all") { _ = store.removePullRequestChecks(draft.keys, taskID: taskID) }
              .buttonStyle(.plain).foregroundStyle(.secondary)
          }
          if expanded {
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(draft.checks, id: \.attachmentKey) { check in
                  HStack {
                    Image(systemName: "xmark.circle").foregroundStyle(.red)
                    Text(check.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove") { _ = store.removePullRequestChecks([check.attachmentKey], taskID: taskID) }
                      .buttonStyle(.plain).foregroundStyle(.secondary)
                      .accessibilityLabel("Remove \(check.name)")
                  }
                }
              }
            }.frame(maxHeight: 160)
          }
        }.appFont(.caption).padding(8)
          .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }
}
