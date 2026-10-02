import SwiftUI

struct TaskPullRequestCodeTreeView: View {
  let nodes: [GitHubPRCodeTreeNode]
  let state: GitHubPRCodeState
  let count: (GitHubPRCodeFile) -> Int
  @State private var collapsed = Set<String>()
  @FocusState private var focusedID: String?

  private var rows: [GitHubPRCodeTreeNode.Row] {
    GitHubPRCodeTreeNode.visibleRows(nodes, collapsed: collapsed)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows) { row in
        button(row)
      }
    }.appFont(size: 12)
  }

  private func button(_ row: GitHubPRCodeTreeNode.Row) -> some View {
    let node = row.node
    let selected = node.file != nil && state.activeFilteredPath == node.id
    return Button { activate(node) } label: {
      HStack(spacing: 6) {
        if let file = node.file {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          Text(node.name).lineLimit(1)
          Spacer(minLength: 0)
          if count(file) > 0 { Label("\(count(file))", systemImage: "bubble.right").foregroundStyle(.secondary) }
          Text(marker(file.kind)).foregroundStyle(color(file.kind))
        } else {
          Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
            .font(.system(size: 9))
          Image(systemName: "folder").foregroundStyle(.secondary)
          Text(node.name).lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      .padding(.leading, CGFloat(row.depth) * 12 + 8).padding(.trailing, 8)
      .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
      .contentShape(Rectangle())
      .background(selected ? Color.accentColor.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(node.id)
    .accessibilityLabel(node.id)
    .accessibilityValue(node.file == nil ? (collapsed.contains(node.id) ? "已收起" : "已展开")
      : (selected ? "已选中" : "未选中"))
    .accessibilityIdentifier((node.file == nil ? "pull-request-code-folder-" : "pull-request-code-file-") + node.id)
    .focused($focusedID, equals: node.id)
    .onKeyPress(.upArrow) { move(.up, from: node.id) }
    .onKeyPress(.downArrow) { move(.down, from: node.id) }
    .onKeyPress(.leftArrow) { move(.left, from: node.id) }
    .onKeyPress(.rightArrow) { move(.right, from: node.id) }
    .onKeyPress(.home) { move(.first, from: node.id) }
    .onKeyPress(.end) { move(.last, from: node.id) }
    .onKeyPress(.return) { activate(node); return .handled }
  }

  private func activate(_ node: GitHubPRCodeTreeNode) {
    if let file = node.file { state.select(file.path) }
    else if collapsed.contains(node.id) { collapsed.remove(node.id) }
    else { collapsed.insert(node.id) }
  }

  private func move(_ direction: GitHubPRCodeTreeKeyboard.Direction, from id: String) -> KeyPress.Result {
    guard let target = GitHubPRCodeTreeKeyboard.move(direction, from: id, rows: rows,
      collapsed: &collapsed) else { return .ignored }
    focusedID = target
    return .handled
  }

  private func marker(_ kind: GitHubPRCodeFile.Kind) -> String {
    switch kind { case .modified: "M"; case .added: "A"; case .deleted: "D"; case .renamed: "R"; case .copied: "C" }
  }
  private func color(_ kind: GitHubPRCodeFile.Kind) -> Color {
    switch kind { case .added: .green; case .deleted: .red; default: .secondary }
  }
}
