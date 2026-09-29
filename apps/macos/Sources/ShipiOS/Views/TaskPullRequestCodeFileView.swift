import SwiftUI

struct TaskPullRequestCodeFileView<Comment: View>: View {
  let file: GitHubPRCodeFile
  let state: GitHubPRCodeState
  let threads: [GitHubPRReviewThread]
  @ViewBuilder let comment: (GitHubPRReviewThread) -> Comment
  @Environment(\.appAppearance) private var appearance
  private var lines: [ReviewDiffLine] { file.diff.lines.filter { $0.canComment || $0.kind == .header } }
  private var collapsed: Bool { state.collapsed.contains(file.path) }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { state.toggle(file.path) } label: {
        HStack(spacing: 8) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down").appFont(size: 10)
          Text(file.path).lineLimit(1)
          Spacer(minLength: 12)
          Text("+\(file.diff.additions)").foregroundStyle(.green)
          Text("−\(file.diff.deletions)").foregroundStyle(.red)
        }.appFont(size: 12).padding(10).contentShape(Rectangle())
      }.buttonStyle(.plain).onKeyPress(.return) { state.toggle(file.path); return .handled }
        .accessibilityLabel(file.path).accessibilityValue(collapsed ? "已收起" : "已展开")
      if !collapsed {
        Divider()
        if let old = file.oldPath, old != file.path {
          Text(old + " → " + file.path).appFont(size: 11).foregroundStyle(.secondary).padding(8)
        }
        if file.binary { Text("二进制文件已修改").appFont(size: 12).foregroundStyle(.secondary).padding(12) }
        else if lines.isEmpty { Text("文件内容没有文本差异").appFont(size: 12).foregroundStyle(.secondary).padding(12) }
        else if state.split {
          ForEach(GitHubPRSplitLine.rows(lines)) { row in
            HStack(alignment: .top, spacing: 0) {
              splitCell(row.left, left: true)
              Divider()
              splitCell(row.right, left: false)
            }
            ForEach(rowThreads(row)) { thread in comment(thread).padding(8) }
          }
        } else {
          ForEach(lines) { line in
            HStack(alignment: .top, spacing: 0) {
              number(line.oldLine); number(line.newLine)
              code(line)
            }.background(background(line)).id(file.lineID(line))
            ForEach(lineThreads(line)) { thread in comment(thread).padding(8) }
          }
        }
        ForEach(unplacedThreads) { thread in
          VStack(alignment: .leading, spacing: 4) {
            Text("评论位置不在当前差异中").appFont(size: 11).foregroundStyle(.secondary)
            comment(thread)
          }.padding(8)
        }
      }
    }.frame(minWidth: state.split ? 560 : 300, maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
  }
  @ViewBuilder private func splitCell(_ line: ReviewDiffLine?, left: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      number(left ? line?.oldLine : line?.newLine)
      if let line { code(line) } else { Text(" ").frame(maxWidth: .infinity, alignment: .leading) }
    }.frame(maxWidth: .infinity, alignment: .leading).background(line.map(background) ?? .clear)
      .id(line.map { file.lineID($0) + (left ? "-left" : "") } ?? file.path + "-blank")
      .overlay(alignment: .topLeading) {
        if let line, state.position?.side == (left ? .left : .right) {
          Color.clear.frame(width: 1, height: 1).id(file.lineID(line))
        }
      }
  }
  private func number(_ value: Int?) -> some View {
    Text(value.map(String.init) ?? "").appFont(size: 11, design: .monospaced).foregroundStyle(.secondary)
      .frame(width: 38, alignment: .trailing).padding(.trailing, 8)
  }
  private func code(_ line: ReviewDiffLine) -> some View {
    Text(line.displayText(markerStyle: appearance.diffMarkerStyle)).appFont(size: 11, design: .monospaced)
      .textSelection(.enabled).fixedSize(horizontal: !state.wrap, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
      .foregroundStyle(line.kind == .header ? Color.secondary : Color.primary)
  }
  private func background(_ line: ReviewDiffLine) -> Color {
    if let target = state.position, file.matches(target),
      (target.side == .left ? line.oldLine : line.newLine) == target.line { return appearance.accentColor.opacity(0.2) }
    guard appearance.diffMarkerStyle == .color else { return .clear }
    switch line.kind { case .addition: return .green.opacity(0.1); case .deletion: return .red.opacity(0.1); default: return .clear }
  }
  private func lineThreads(_ line: ReviewDiffLine) -> [GitHubPRReviewThread] {
    threads.filter { thread in
      guard let position = thread.position else { return false }
      return (position.side == .left ? line.oldLine : line.newLine) == position.line
    }
  }
  private func rowThreads(_ row: GitHubPRSplitLine) -> [GitHubPRReviewThread] {
    let ids = Set([row.left, row.right].compactMap { $0 }.flatMap(lineThreads).map(\.id))
    return threads.filter { ids.contains($0.id) }
  }
  private var unplacedThreads: [GitHubPRReviewThread] {
    let placed = Set(lines.flatMap(lineThreads).map(\.id))
    return threads.filter { !placed.contains($0.id) }
  }
}
