import SwiftUI

struct TaskPullRequestCodeTreeView: View {
  let nodes: [GitHubPRCodeTreeNode]
  let state: GitHubPRCodeState
  let count: (GitHubPRCodeFile) -> Int
  var depth = 0
  @State private var collapsed = Set<String>()
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(nodes) { node in
        if let file = node.file {
          Button { state.select(file.path) } label: {
            HStack(spacing: 6) {
              Image(systemName: "doc.text").foregroundStyle(.secondary)
              Text(node.name).lineLimit(1)
              Spacer(minLength: 0)
              if count(file) > 0 { Label("\(count(file))", systemImage: "bubble.right").foregroundStyle(.secondary) }
              Text(marker(file.kind)).foregroundStyle(color(file.kind))
            }.padding(.leading, CGFloat(depth) * 12 + 8).padding(.trailing, 8).padding(.vertical, 5)
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              .background(state.activeFilteredPath == file.path ? Color.accentColor.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
          }.buttonStyle(.plain).help(file.path).accessibilityLabel(file.path)
            .accessibilityIdentifier("pull-request-code-file-" + file.path)
            .onKeyPress(.return) { state.select(file.path); return .handled }
        } else {
          Button {
            if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down").font(.system(size: 9))
              Image(systemName: "folder").foregroundStyle(.secondary)
              Text(node.name).lineLimit(1)
              Spacer(minLength: 0)
            }.padding(.leading, CGFloat(depth) * 12 + 8).padding(.vertical, 5).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel(node.id)
            .accessibilityValue(collapsed.contains(node.id) ? "已收起" : "已展开")
          if !collapsed.contains(node.id) {
            TaskPullRequestCodeTreeView(nodes: node.children, state: state, count: count, depth: depth + 1)
          }
        }
      }
    }.appFont(size: 12)
  }
  private func marker(_ kind: GitHubPRCodeFile.Kind) -> String {
    switch kind { case .modified: "M"; case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .copied: "C" }
  }
  private func color(_ kind: GitHubPRCodeFile.Kind) -> Color {
    switch kind { case .added: .green; case .deleted: .red; default: .secondary }
  }
}
