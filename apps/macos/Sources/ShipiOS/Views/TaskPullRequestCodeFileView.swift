import SwiftUI

struct TaskPullRequestCodeFileView<Comment: View>: View {
  let file: GitHubPRCodeFile
  let state: GitHubPRCodeState
  let threads: [GitHubPRReviewThread]
  var inline: PullRequestInlineCommentControls? = nil
  @State private var selection = PullRequestCodeSelection()
  @State private var selectionError: String?
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
        if let selectionError { Text(selectionError).appFont(size: 12).foregroundStyle(.red).padding(8) }
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
            draftRows(for: [row.left, row.right].compactMap { $0 })
          }
        } else {
          ForEach(lines) { line in
            HStack(alignment: .top, spacing: 0) {
              gutter(line, side: .left); gutter(line, side: .right)
              code(line)
            }.background(background(line)).id(file.lineID(line))
            ForEach(lineThreads(line)) { thread in comment(thread).padding(8) }
            draftRows(for: [line])
          }
        }
        if let inline {
          ForEach(inlineDrafts.filter { _, draft in
            guard case .inline(_, let anchor) = draft.target else { return false }
            return !lines.contains { (anchor.position.side == .left ? $0.oldLine : $0.newLine) == anchor.position.line }
          }, id: \.id) { entry in
            inlineDraft(entry.id, draft: entry.draft, controls: inline).padding(8)
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
      .onChange(of: file.diff.fingerprint) { _, _ in selection.clear(); selectionError = nil }
      .onChange(of: inline?.code.identity) { _, _ in selection.clear(); selectionError = nil }
      .onChange(of: inline?.discussion.staleInline) { _, anchor in
        if anchor?.identity == inline?.code.identity { selection.clear() }
      }
  }
  @ViewBuilder private func splitCell(_ line: ReviewDiffLine?, left: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      if let line { gutter(line, side: left ? .left : .right) } else { number(nil) }
      if let line { code(line) } else { Text(" ").frame(maxWidth: .infinity, alignment: .leading) }
    }.frame(maxWidth: .infinity, alignment: .leading).background(line.map(background) ?? .clear)
      .id(line.map { file.lineID($0) + (left ? "-left" : "") } ?? file.path + "-blank")
      .overlay(alignment: .topLeading) {
        if let line, state.position?.side == (left ? .left : .right) {
          Color.clear.frame(width: 1, height: 1).id(file.lineID(line))
        }
      }
  }
  private var inlineDrafts: [(id: String, draft: GitHubPRCommentDraft)] {
    inline?.discussion.inlineDrafts.filter { _, draft in
      if case .inline(_, let anchor) = draft.target { return anchor.position.path == file.path }; return false
    } ?? []
  }
  @ViewBuilder private func draftRows(for rows: [ReviewDiffLine]) -> some View {
    if let inline {
      ForEach(inlineDrafts.filter { _, draft in
        guard case .inline(_, let anchor) = draft.target else { return false }
        return rows.contains { (anchor.position.side == .left ? $0.oldLine : $0.newLine) == anchor.position.line }
      }, id: \.id) { entry in inlineDraft(entry.id, draft: entry.draft, controls: inline).padding(8) }
    }
  }
  private func inlineDraft(_ id: String, draft: GitHubPRCommentDraft, controls: PullRequestInlineCommentControls) -> some View {
    TaskPullRequestInlineCommentView(id: id, draft: draft, controls: controls) {
      controls.discussion.cancelDraft(id); selection.clear()
    }
  }
  @ViewBuilder private func gutter(_ line: ReviewDiffLine, side: GitHubPRCommentPosition.Side) -> some View {
    let value = side == .left ? line.oldLine : line.newLine
    if let value, let inline {
      let point = GitHubPRCodePoint(side: side, line: value, row: line.id)
      number(value).background(selection.contains(point) ? Color.accentColor.opacity(0.2) : .clear)
        .overlay { PullRequestCodeGutter(point: point, selection: selection,
          enabled: inline.enabled, selected: selection.contains(point), commit: { position in
            do {
              let anchor = try GitHubPRInlineAnchor(position: position, snapshot: inline.code)
              _ = inline.discussion.beginInline(anchor); selectionError = nil
            } catch { selectionError = error.localizedDescription }
          }, path: file.path) }
    } else { number(value) }
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
