import SwiftUI

struct LastTurnReviewView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let snapshot: LastTurnReviewSnapshot
  var taskID: String?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
      if snapshot.source.root == nil && !snapshot.files.isEmpty {
        Text("原回合的路径基准不可用，仍可查看完整差异。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      ForEach(snapshot.files) { file in
        LastTurnReviewFileView(store: store, workspace: workspace, snapshot: snapshot,
          file: file, taskID: taskID)
          .id(snapshot.source.runID + ":" + String(file.id))
      }
    }
  }
}

private struct LastTurnReviewFileView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let snapshot: LastTurnReviewSnapshot
  let file: CodexTurnDiffFile
  var taskID: String?
  @State private var syntax = CodeSyntaxState()
  private var key: String { "lastTurn:" + snapshot.source.runID + ":" + file.path }
  private var expanded: Bool { !workspace.collapsedReviewFiles.contains(key) }

  var body: some View {
    let diff = snapshot.patches[file.id] ?? ReviewDiff("")
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button(action: toggle) {
          Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 16)
        }.buttonStyle(.plain).accessibilityLabel((expanded ? "折叠 " : "展开 ") + file.path)
        Button(file.path) { openFile() }.buttonStyle(.plain).appFont(.caption)
          .lineLimit(1).help("在" + store.preferredEditor.title + "打开 " + file.path)
          .disabled(snapshot.source.root == nil)
        Spacer(minLength: 8)
        Text("+\(diff.additions)").foregroundStyle(.green)
        Text("−\(diff.deletions)").foregroundStyle(.red)
      }.appFont(.caption2).padding(10)
        .background(Color.primary.opacity(0.04).contentShape(Rectangle()).onTapGesture(perform: toggle))
      if expanded {
        if store.reviewDiffWrap {
          diffRows(diff).frame(maxWidth: .infinity, alignment: .leading)
            .background(store.appearance.codeBackgroundColor)
        } else {
          ScrollView(.horizontal) {
            diffRows(diff)
              .frame(minWidth: store.reviewDiffSplit ? 720 : 0, maxWidth: .infinity, alignment: .leading)
          }.background(store.appearance.codeBackgroundColor)
        }
      }
    }.overlay(Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
      .task(id: CodeSyntaxIdentity(path: file.path, fingerprint: diff.fingerprint + String(expanded),
        wordDiffs: store.reviewWordDiffs, themes: store.appearance.codeThemes)) {
        if expanded { await syntax.load(CodeSyntaxInput(path: file.path, diff: diff, wordDiffs: store.reviewWordDiffs, themes: store.appearance.codeThemes)) }
        else { syntax.cancel() }
      }
      .onDisappear { syntax.cancel() }
  }

  private func diffRows(_ diff: ReviewDiff) -> some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      if store.reviewDiffSplit {
        ForEach(GitHubPRSplitLine.rows(diff.lines)) { row in
          if let line = row.left, line.kind == .header || line.kind == .metadata {
            codeLine(line, diff: diff)
            comments(for: [line], diff: diff)
          } else {
            HStack(alignment: .top, spacing: 0) {
              splitCell(row.left, side: .old, diff: diff)
              Divider()
              splitCell(row.right, side: .new, diff: diff)
            }
            comments(for: [row.left, row.right].compactMap { $0 }, diff: diff)
          }
        }
      } else {
        ForEach(diff.lines) { line in
          codeLine(line, diff: diff)
          comments(for: [line], diff: diff)
        }
      }
    }
  }

  @ViewBuilder private func splitCell(_ line: ReviewDiffLine?, side: ReviewCodeLine.Side,
    diff: ReviewDiff) -> some View {
    if let line { codeLine(line, diff: diff, side: side) }
    else { Color.clear.frame(maxWidth: .infinity).frame(minHeight: 20) }
  }

  private func codeLine(_ line: ReviewDiffLine, diff: ReviewDiff,
    side: ReviewCodeLine.Side? = nil) -> some View {
    ReviewCodeLine(line: line,
      addComment: { store.beginReviewComment(anchor(line, patch: diff), taskID: taskID) },
      openLine: { openFile(line: line.workingLine) },
      commentsEnabled: snapshot.source.root != nil && !(side == .old && line.kind == .context),
      openEnabled: snapshot.source.root != nil,
      tokens: syntax.tokens(line, identity: .init(path: file.path, fingerprint: diff.fingerprint)),
      changes: store.reviewWordDiffs ? syntax.changes(line,
        identity: .init(path: file.path, fingerprint: diff.fingerprint)) : [],
      side: side, wrap: store.reviewDiffWrap)
  }

  @ViewBuilder private func comments(for lines: [ReviewDiffLine], diff: ReviewDiff) -> some View {
    let anchors = lines.map { anchor($0, patch: diff) }
    ForEach(store.reviewComments(taskID: taskID).filter { comment in anchors.contains(comment.anchor) }) { comment in
      ReviewCommentView(store: store, comment: comment, taskID: taskID)
        .frame(width: 280).padding(8)
    }
  }

  private func toggle() {
    if expanded { workspace.collapsedReviewFiles.insert(key) }
    else { workspace.collapsedReviewFiles.remove(key) }
  }
  private func openFile(line: Int? = nil) {
    Task { await store.openLastTurnFile(file, snapshot: snapshot, in: workspace, line: line) }
  }
  private func anchor(_ line: ReviewDiffLine, patch: ReviewDiff) -> ReviewAnchor {
    .init(project: workspace.root.map(GitBranchService.canonicalRoot)?.path ?? "",
      path: file.path, scope: GitReviewScope.lastTurn.title, revision: snapshot.source.runID,
      fingerprint: patch.fingerprint, oldLine: line.oldLine, newLine: line.newLine,
      code: String(line.text.dropFirst()), turnRunID: snapshot.source.runID,
      originRoot: snapshot.source.root?.path)
  }
}
