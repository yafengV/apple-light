import AppKit
import SwiftUI

struct ReviewFileView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let file: GitFile
  let root: URL
  let scope: GitReviewScope
  let revision: String
  var taskID: String?
  @State private var patch: ReviewDiff?
  @State private var failure: String?
  @State private var loading = false
  private var key: String { scope.rawValue + ":" + revision + ":" + file.path }
  private var expanded: Bool { !workspace.collapsedReviewFiles.contains(key) }

  var body: some View {
    let editableHunks: [Int: ReviewHunk] =
      patch.flatMap { diff in
        diff.supportsHunkActions
          ? Dictionary(uniqueKeysWithValues: diff.hunks.map { ($0.id, $0) }) : nil
      } ?? [:]
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded {
        if loading {
          ProgressView().controlSize(.small).padding(12)
        } else if let failure {
          Text(failure).appFont(.caption).foregroundStyle(.secondary).padding(12)
        } else if let patch {
          if patch.lines.isEmpty {
            Text("没有文本差异").appFont(.caption).foregroundStyle(.secondary).padding(12)
          }
          ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(patch.lines) { line in
                if !scope.isHistorical, !file.untracked,
                  let hunk = editableHunks[line.id]
                {
                  ReviewHunkControls(
                    workspace: workspace, file: file, hunk: hunk,
                    snapshot: patch, project: root, scope: scope)
                } else {
                  ReviewCodeLine(
                    line: line,
                    addComment: {
                      store.beginReviewComment(anchor(line, patch: patch), taskID: taskID)
                    },
                    openLine: { openFile(line: line.workingLine) })
                }
                ForEach(matchingComments(line, patch: patch)) { comment in
                  ReviewCommentView(store: store, comment: comment, taskID: taskID)
                    .frame(width: 280)
                    .padding(8)
                }
              }
            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .overlay(Rectangle().stroke(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
    .task(id: "\(workspace.reviewSnapshot):\(expanded)") {
      guard expanded else { return }
      patch = nil
      failure = nil
      loading = true
      do {
        let value = try await GitReviewService.fileDiff(
          file, scope: scope, arguments: workspace.reviewArguments, at: root)
        guard !Task.isCancelled else { return }
        patch = value
      } catch {
        guard !Task.isCancelled else { return }
        failure = error.localizedDescription
      }
      loading = false
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        toggle()
      } label: {
        Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 16)
      }.buttonStyle(.plain).accessibilityLabel((expanded ? "折叠 " : "展开 ") + file.path)
      Button(file.comparisonPaths(scope: scope).joined(separator: " → ")) { openFile() }
        .buttonStyle(.plain).appFont(.caption).lineLimit(1).help(
          "在" + store.preferredEditor.title + "打开 " + file.path)
      Spacer(minLength: 8)
      if let patch {
        Text("+\(patch.additions)").foregroundStyle(.green)
        Text("−\(patch.deletions)").foregroundStyle(.red)
      }
      if !scope.isHistorical {
        Button(scope == .staged ? "取消暂存" : "暂存") {
          Task { await workspace.stage(file.path, undo: scope == .staged) }
        }.buttonStyle(.borderless).disabled(workspace.gitBusy)
      }
      if scope == .unstaged {
        Menu {
          Button("撤销文件的未暂存修改…") {
            if let snapshot = workspace.batchSnapshot {
              Task { await workspace.prepareDiscard(snapshot, path: file.path) }
            }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("文件操作：" + file.path)
        .disabled(
          workspace.batchSnapshot == nil || workspace.gitBusy || workspace.reviewLoading
            || workspace.gitRefreshing)
      }
    }.appFont(.caption2).padding(10)
      .background(Color.primary.opacity(0.04).contentShape(Rectangle()).onTapGesture { toggle() })
  }
  private func toggle() {
    if expanded {
      workspace.collapsedReviewFiles.insert(key)
    } else {
      workspace.collapsedReviewFiles.remove(key)
    }
  }
  private func openFile(line: Int? = nil) {
    Task { await store.openProjectFile(file.path, root: root, line: line) }
  }
  private func anchor(_ line: ReviewDiffLine, patch: ReviewDiff) -> ReviewAnchor {
    .init(
      project: root.path, path: file.path, scope: scope.title, revision: revision,
      fingerprint: patch.fingerprint, oldLine: line.oldLine, newLine: line.newLine,
      code: String(line.text.dropFirst()),
      oldPath: file.comparisonPaths(scope: scope).count > 1 ? file.originalPath : nil)
  }
  private func matchingComments(_ line: ReviewDiffLine, patch: ReviewDiff) -> [ReviewComment] {
    guard line.canComment else { return [] }
    let location = anchor(line, patch: patch)
    return store.reviewComments(taskID: taskID).filter { $0.anchor == location }
  }
}

private struct ReviewCodeLine: View {
  let line: ReviewDiffLine
  let addComment: () -> Void
  let openLine: () -> Void
  @Environment(\.appAppearance) private var appearance
  @State private var hovering = false
  @FocusState private var focused: Bool
  var body: some View {
    HStack(spacing: 0) {
      if line.canComment {
        Button(action: addComment) { Image(systemName: "plus").frame(width: 22, height: 20) }
          .buttonStyle(.plain).focused($focused).opacity(hovering || focused ? 1 : 0)
          .help("添加行内评论").accessibilityLabel("为第 \(line.newLine ?? line.oldLine ?? 0) 行添加评论")
      } else {
        Color.clear.frame(width: 22, height: 20)
      }
      Text(line.oldLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
        .foregroundStyle(.secondary)
      Text(line.newLine.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
        .foregroundStyle(.secondary)
      Text(line.displayText(markerStyle: appearance.diffMarkerStyle)).textSelection(.enabled)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .foregroundStyle(line.kind == .header ? Color.secondary : Color.primary)
        .overlay {
          if line.canComment {
            CommandClickTarget(
              action: openLine, addComment: addComment, code: String(line.text.dropFirst()))
          }
        }
    }.appFont(size: 11, design: .monospaced).frame(maxWidth: .infinity, alignment: .leading)
      .background(diffBackground)
      .onHover { hovering = $0 }
      .contextMenu {
        if line.canComment {
          Button("添加行内评论", action: addComment)
          Button("在编辑器打开此行", action: openLine)
        }
      }
  }

  private var diffBackground: Color {
    guard appearance.diffMarkerStyle == .color else { return .clear }
    if line.kind == .addition { return Color.green.opacity(0.10) }
    if line.kind == .deletion { return Color.red.opacity(0.10) }
    return .clear
  }
}
