import SwiftUI

/// Full-file review for replacements too large to read safely between editor lines.
struct FileSelectionFullReviewView: View {
  @Bindable var workspace: DeveloperWorkspace
  let request: FileSelectionEditRequest
  let proposal: FileSelectionEditProposal
  @Environment(\.appAppearance) private var appearance

  private var session: FileSelectionEditSession { workspace.selectionEdit }
  private var diff: ReviewDiff { FileSelectionReviewDiff.make(old: request.source, new: proposal.content) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "text.badge.checkmark")
        Text("审阅文件修改").appFont(.headline)
        Text(request.path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button("关闭") { reject() }.accessibilityLabel("关闭文件修改审阅")
      }.padding(12)
      Divider()
      if !session.canApply(path: workspace.selectedFile, source: workspace.fileText) {
        Text("文件或选区已变化，请返回编辑并重新生成建议。")
          .appFont(.caption).foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading).padding(10)
      }
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(diff.lines) { line in
            ReviewCodeLine(line: line, addComment: {}, openLine: {},
              commentsEnabled: false, openEnabled: false)
              .fixedSize(horizontal: true, vertical: false)
          }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
      }.background(appearance.codeBackgroundColor)
      Divider()
      HStack {
        Button("拒绝") { reject() }
        Button("编辑要求") { session.revise() }
        Spacer()
        Button("接受修改") {
          if session.accept(path: workspace.selectedFile, source: workspace.fileText) {
            workspace.fileFocusRequest = UUID()
          }
        }.buttonStyle(.borderedProminent)
          .disabled(!session.canApply(path: workspace.selectedFile, source: workspace.fileText))
      }.padding(12)
    }
    .background(appearance.codeBackgroundColor)
    .onExitCommand { reject() }
    .accessibilityLabel("完整文件差异审阅")
  }

  private func reject() {
    session.close()
    workspace.fileFocusRequest = UUID()
  }
}
