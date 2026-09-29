import SwiftUI

struct TaskPullRequestCodeView: View {
  let state: GitHubPRCodeState
  let discussion: GitHubPRDiscussionState
  let enabled: Bool
  let writable: Bool
  let mentionRequest: GitHubPRMentionRequest?
  let open: (URL) -> Void
  let submit: (GitHubPRDiscussionAction, String?) -> Void
  let retry: () -> Void
  let retryComments: () -> Void
  var confirm: () -> Void = {}
  var metadataLoading = false
  var metadataError: String? = nil
  @State private var comments = GitHubPRCommentCollapseState()
  @State private var fileWidth: CGFloat = 260
  @State private var dragWidth: CGFloat?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if let identity = state.snapshot?.identity, discussion.isCodeStale(identity) {
        HStack {
          Text("PR 代码版本已变化，原评论草稿已保留。")
          Button("刷新差异", action: retry).disabled(state.loading || metadataLoading || discussion.busy)
          Spacer(minLength: 0)
        }.appFont(size: 12).padding(8)
      }
      if discussion.uncertain != nil {
        HStack {
          Text("评论结果尚未确认；草稿已保留，没有重复发送。")
          Button("重新读取结果", action: confirm).disabled(discussion.busy)
          Spacer(minLength: 0)
        }.appFont(size: 12).padding(8)
      }
      if let notice = discussion.notice {
        HStack {
          Text(notice)
          Button("刷新评论", action: retryComments).disabled(discussion.busy || discussion.refreshing)
          Spacer(minLength: 0)
        }.appFont(size: 12).padding(8)
      }
      if discussion.loading {
        ProgressView("读取评论…").controlSize(.small).padding(8)
      } else if discussion.readError != nil {
        HStack {
          Label("评论未能载入", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
          Button("重试评论", action: retryComments).disabled(discussion.refreshing || discussion.busy)
          Spacer(minLength: 0)
        }.appFont(size: 12).padding(8)
      }
      if state.loading || metadataLoading { ProgressView("读取 PR 修改…").frame(maxWidth: .infinity, maxHeight: .infinity) }
      else if let error = state.error {
        ContentUnavailableView {
          Label("无法读取修改", systemImage: "exclamationmark.triangle")
        } description: { Text(error) } actions: { Button("重试", action: retry) }
      } else if state.snapshot == nil {
        ContentUnavailableView {
          Label("PR 代码版本不可用", systemImage: "arrow.triangle.pullrequest")
        } description: { Text(metadataError ?? "刷新 PR 后重试。") } actions: { Button("刷新 PR", action: retry) }
      } else if state.files.isEmpty {
        ContentUnavailableView("没有修改的文件", systemImage: "doc")
      } else {
        GeometryReader { geometry in
          let width = min(fileWidth, max(220, geometry.size.width * 0.4))
          let narrow = geometry.size.width < 680
          HStack(spacing: 0) {
            differences
            if state.showsFiles && !narrow {
              divider(width: width)
              fileTree.frame(width: width)
            }
          }
          .overlay(alignment: .trailing) {
            if state.showsFiles && narrow {
              fileTree.frame(width: min(360, max(0, geometry.size.width - 56)))
                .background(.regularMaterial).overlay(alignment: .leading) { Divider() }
            }
          }
        }
      }
    }
    .accessibilityIdentifier("pull-request-code-page")
    .onChange(of: state.snapshot) { _, snapshot in
      if let snapshot { discussion.codeReloaded(snapshot) }
    }
    .onChange(of: discussion.snapshot?.commentCards, initial: true) { _, cards in
      comments.sync(cards ?? [], drafts: discussion.drafts)
    }
    .onChange(of: discussion.drafts) { _, drafts in comments.sync(discussion.snapshot?.commentCards ?? [], drafts: drafts) }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      if let identity = state.snapshot?.identity {
        Text(identity.headBranch + " → " + identity.baseBranch).lineLimit(1).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Menu {
        Button(state.wrap ? "关闭自动换行" : "开启自动换行") { state.wrap.toggle() }
        Button(state.allCollapsed ? "展开全部差异" : "收起全部差异") { state.toggleAll() }
      } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
        .accessibilityLabel("差异选项")
      Button { state.split.toggle() } label: {
        Image(systemName: state.split ? "rectangle.split.1x2" : "rectangle.split.2x1")
      }.buttonStyle(.plain).help(state.split ? "切换为统一差异" : "切换为并排差异")
        .accessibilityLabel(state.split ? "切换为统一差异" : "切换为并排差异")
      Button { state.showsFiles.toggle() } label: { Image(systemName: "sidebar.right") }
        .buttonStyle(.plain).help(state.showsFiles ? "隐藏文件树" : "显示文件树")
        .accessibilityLabel(state.showsFiles ? "隐藏文件树" : "显示文件树")
        .accessibilityValue(state.showsFiles ? "已显示" : "已隐藏")
    }.appFont(size: 13).padding(.horizontal, 12).frame(height: 38).overlay(alignment: .bottom) { Divider() }
  }

  private var differences: some View {
    ScrollViewReader { proxy in
      ScrollView(state.wrap ? .vertical : [.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(state.files) { file in
            TaskPullRequestCodeFileView(file: file, state: state, threads: threads(for: file), inline: inlineControls) { thread in
              if let root = thread.comments.first {
                TaskPullRequestCommentView(card: .init(comment: root, thread: thread), collapse: comments,
                  state: discussion, enabled: enabled, writable: writable, mentionRequest: mentionRequest,
                  open: open, submit: submit, showsCodeContext: false)
              }
            }.id(file.path)
          }
          if let controls = inlineControls {
            ForEach(discussion.inlineDrafts.filter { _, draft in
              guard case .inline(_, let anchor) = draft.target else { return false }
              return !state.files.contains { $0.path == anchor.position.path }
            }, id: \.id) { entry in
              VStack(alignment: .leading, spacing: 4) {
                if case .inline(_, let anchor) = entry.draft.target { Text(anchor.position.path).appFont(size: 12).foregroundStyle(.secondary) }
                TaskPullRequestInlineCommentView(id: entry.id, draft: entry.draft, controls: controls) { discussion.cancelDraft(entry.id) }
              }
            }
          }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      }
      .task(id: state.navigation) {
        guard let path = state.selectedPath, let file = state.files.first(where: { $0.path == path }) else { return }
        // Materialize an offscreen file before addressing its nested line. Repeated jumps
        // get a new task; changing tabs/disappearing cancels any pending positioning.
        proxy.scrollTo(path, anchor: .top)
        if let row = state.rowTarget(in: file) {
          for _ in 0..<4 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled else { return }
            proxy.scrollTo(row, anchor: .center)
          }
        }
      }
    }
  }

  private var inlineControls: PullRequestInlineCommentControls? {
    state.snapshot.map { .init(code: $0, discussion: discussion,
      enabled: enabled && !metadataLoading && !discussion.isCodeStale($0.identity) && discussion.snapshot?.head.lowercased() == $0.identity.head.lowercased(),
      writable: writable, mentionRequest: mentionRequest, submit: submit) }
  }
  private func threads(for file: GitHubPRCodeFile) -> [GitHubPRReviewThread] {
    guard discussion.readError == nil, let snapshot = discussion.snapshot,
      snapshot.head.lowercased() == state.snapshot?.identity.head.lowercased() else { return [] }
    return snapshot.threads.filter { thread in
      guard let position = thread.position else { return false }; return file.matches(position)
    }
  }
  private var fileTree: some View {
    VStack(spacing: 8) {
      TextField("搜索文件", text: Binding(get: { state.query }, set: { state.query = $0 }))
        .textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.top, 8)
        .accessibilityIdentifier("pull-request-code-file-search")
      if state.filteredFiles.isEmpty {
        Text("没有匹配的文件").foregroundStyle(.secondary).padding(8)
      }
      ScrollView {
        TaskPullRequestCodeTreeView(nodes: GitHubPRCodeTreeNode.tree(state.filteredFiles), state: state,
          count: { threads(for: $0).count })
      }
    }.frame(maxHeight: .infinity, alignment: .top)
      .accessibilityIdentifier("pull-request-code-file-tree")
  }

  private func divider(width: CGFloat) -> some View {
    Rectangle().fill(.quaternary).frame(width: 5).contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        if dragWidth == nil { dragWidth = width }
        fileWidth = min(360, max(220, (dragWidth ?? width) - value.translation.width))
      }.onEnded { _ in dragWidth = nil })
      .focusable().onKeyPress(.leftArrow) { fileWidth = min(360, fileWidth + 10); return .handled }
      .onKeyPress(.rightArrow) { fileWidth = max(220, fileWidth - 10); return .handled }
      .accessibilityLabel("文件树宽度").accessibilityValue("\(Int(fileWidth))")
      .accessibilityAdjustableAction { direction in
        fileWidth = min(360, max(220, fileWidth + (direction == .increment ? 10 : -10)))
      }
  }
}
