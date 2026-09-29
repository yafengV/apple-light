import SwiftUI

struct PullRequestCodeFileHeader: View {
  let file: GitHubPRCodeFile
  let state: GitHubPRCodeState
  var copy: (GitHubPRCodeFile) -> Bool = { PullRequestCodeClipboard.copy($0) }
  @State private var hover = false
  @State private var copied = false
  @State private var focus: Control?
  private enum Control: Hashable { case title, copy, fold }
  private var collapsed: Bool { state.collapsed.contains(file.path) }
  private var controlsVisible: Bool { hover || focus != nil }
  private func toggle(_ flags: NSEvent.ModifierFlags) { state.toggle(file.path, all: flags.contains(.option)) }

  var body: some View {
    HStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "doc.text").foregroundStyle(.secondary)
          ViewThatFits(in: .horizontal) {
            pathText.fixedSize(horizontal: true, vertical: false)
            Text(file.headerFilename).lineLimit(1).truncationMode(.middle)
          }
          Text("+\(file.diff.additions)").foregroundStyle(.green).fixedSize()
          Text("−\(file.diff.deletions)").foregroundStyle(.red).fixedSize()
          Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          .accessibilityHidden(true)
          .overlay { button(.title, identifier: "header", label: file.headerDescription, symbol: nil, activate: toggle) }
      button(.copy, identifier: "copy", label: copied ? "已复制路径" : "复制路径",
        symbol: copied ? "checkmark" : "doc.on.doc", activate: { _ in copied = copy(file) })
        .frame(width: 20, height: 24)
        .opacity(controlsVisible ? 1 : 0)
      button(.fold, identifier: "fold", label: "展开/收起文件差异",
        symbol: collapsed ? "chevron.right" : "chevron.down", activate: toggle)
        .frame(width: 20, height: 24)
        .opacity(controlsVisible ? 1 : 0)
    }.appFont(size: 12).padding(.horizontal, 10).frame(height: 34)
      .background(.regularMaterial).onHover { hover = $0 }
      .onChange(of: file.headerRelativePath) { _, _ in copied = false }
      .task(id: copied) {
        guard copied else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        copied = false
      }
  }
  private func button(_ control: Control, identifier: String, label: String, symbol: String?,
    activate: @escaping (NSEvent.ModifierFlags) -> Void) -> some View {
    PullRequestCodeHeaderButton(identifier: "pull-request-code-" + identifier + "-" + file.path,
      label: label, value: collapsed ? "已收起" : "已展开", symbol: symbol, activate: activate,
      focused: { active in
        if active { focus = control } else if focus == control { focus = nil }
      })
  }
  private var pathText: Text {
    file.headerPaths.enumerated().reduce(Text("")) { text, entry in
      let path = entry.element, filename = path.split(separator: "/").last.map(String.init) ?? path
      return text + Text(entry.offset > 0 ? " → " : "")
        + Text(String(path.dropLast(filename.count))).foregroundColor(.secondary)
        + Text(filename).foregroundColor(.primary)
    }
  }
}
