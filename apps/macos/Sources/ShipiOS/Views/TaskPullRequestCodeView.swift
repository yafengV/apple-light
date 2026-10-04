import SwiftUI

struct PullRequestCodeSplitLayout {
  static let dividerWidth: CGFloat = 5
  static let minimumDiffWidth: CGFloat = 420
  static let minimumTreeWidth: CGFloat = 220
  static let defaultLeftRatio = 0.76

  static func treeWidth(in totalWidth: CGFloat, leftRatio: Double) -> CGFloat {
    let available = max(0, totalWidth - dividerWidth)
    let minimum = min(minimumTreeWidth, available)
    let maximum = max(minimum, available - minimumDiffWidth)
    let ratio = leftRatio.isFinite ? min(1, max(0, leftRatio)) : defaultLeftRatio
    return min(maximum, max(minimum, available * (1 - ratio)))
  }

  static func leftRatio(forTreeWidth desired: CGFloat, in totalWidth: CGFloat) -> Double {
    let available = max(0, totalWidth - dividerWidth)
    guard available > 0 else { return defaultLeftRatio }
    let minimum = min(minimumTreeWidth, available)
    let maximum = max(minimum, available - minimumDiffWidth)
    let width = min(maximum, max(minimum, desired))
    return Double(1 - width / available)
  }
}

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
  var store: WorkspaceStore? = nil
  @State private var comments = GitHubPRCommentCollapseState()
  @State private var dragWidth: CGFloat?
  @AppStorage("shipios.pullRequest.code.leftSplitRatio") private var leftSplitRatio = PullRequestCodeSplitLayout.defaultLeftRatio
  @AppStorage("shipios.review.richPreviewEnabled") private var richPreviewEnabled = true

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if let error = store?.generalSettingsError {
        Text(error).appFont(size: 12).foregroundStyle(.red).padding(8)
      }
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
          let width = PullRequestCodeSplitLayout.treeWidth(in: geometry.size.width, leftRatio: leftSplitRatio)
          let narrow = geometry.size.width < 680
          HStack(spacing: 0) {
            differences
            if state.showsFiles && !narrow {
              divider(width: width, totalWidth: geometry.size.width)
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
    .onChange(of: discussion.snapshot?.inlineCommentCards, initial: true) { _, cards in
      comments.sync(cards ?? [], drafts: discussion.drafts)
    }
    .onChange(of: discussion.drafts) { _, drafts in comments.sync(discussion.snapshot?.inlineCommentCards ?? [], drafts: drafts) }
    .onChange(of: store?.reviewDiffSplit, initial: true) { _, split in
      if let split { state.split = split }
    }
    .onChange(of: store?.reviewDiffWrap, initial: true) { _, wrap in
      if let wrap { state.wrap = wrap }
    }
    .onDisappear { state.endNavigation() }
  }

  private var toolbar: some View {
    GeometryReader { geometry in
      HStack(spacing: 8) {
        if geometry.size.width >= 400, let identity = state.snapshot?.identity {
          HStack(spacing: 6) {
            Text(identity.headBranch).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").appFont(size: 10).accessibilityHidden(true)
            Text(identity.baseBranch).lineLimit(1).truncationMode(.middle)
          }
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(identity.headBranch + " 合并到 " + identity.baseBranch)
        } else { Spacer(minLength: 0) }
        Menu {
          Button("刷新差异", action: retry)
            .disabled(state.loading || metadataLoading)
          Button(state.wrap ? "关闭自动换行" : "开启自动换行") {
            if let store { store.reviewDiffWrap.toggle() }
            else { state.wrap.toggle() }
          }
          Divider()
          Button(richPreviewEnabled ? "关闭富文本预览" : "开启富文本预览") {
            richPreviewEnabled.toggle()
          }
          .accessibilityIdentifier("pull-request-rich-preview-toggle")
          if let store { CodeWordDiffMenu(store: store) }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton)
          .accessibilityLabel("差异选项")
        Button { state.toggleAll() } label: {
          Image(systemName: state.groupExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }.buttonStyle(.plain).help(state.groupExpanded ? "收起全部差异" : "展开全部差异")
          .accessibilityLabel(state.groupExpanded ? "收起全部差异" : "展开全部差异")
        Button {
          if let store { store.reviewDiffSplit.toggle() }
          else { state.split.toggle() }
        } label: {
          Image(systemName: state.split ? "rectangle.split.2x1" : "rectangle.split.1x2")
        }.buttonStyle(.plain).help(state.split ? "切换为统一差异" : "切换为并排差异")
          .accessibilityLabel(state.split ? "切换为统一差异" : "切换为并排差异")
        Button { state.showsFiles.toggle() } label: { Image(systemName: "sidebar.right") }
          .buttonStyle(.plain).help(state.showsFiles ? "隐藏文件树" : "显示文件树")
          .accessibilityLabel(state.showsFiles ? "隐藏文件树" : "显示文件树")
          .accessibilityValue(state.showsFiles ? "已显示" : "已隐藏")
      }
      .appFont(size: 13).padding(.horizontal, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) { Divider() }
    }
    .frame(height: 38)
  }

  private var differences: some View {
    GeometryReader { geometry in differences(width: max(0, geometry.size.width - 24)) }
  }
  private func differences(width: CGFloat) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
          ForEach(state.files) { file in
            Section {
              TaskPullRequestCodeFileView(file: file, state: state, threads: threads(for: file), inline: inlineControls,
                showsHeader: false, viewportWidth: width, wordDiffsEnabled: store?.reviewWordDiffs ?? false,
                richPreviewEnabled: richPreviewEnabled, openLink: open) { thread in
                if let root = thread.comments.first {
                  TaskPullRequestCommentView(card: .init(comment: root, thread: thread, isInline: true), collapse: comments,
                    state: discussion, enabled: enabled, writable: writable, mentionRequest: mentionRequest,
                    open: open, submit: submit, showsCodeContext: false)
                }
              }.padding(.bottom, 14)
                .background(alignment: .topLeading) {
                  PullRequestCodeScrollAnchor(request: state.navigationPending && state.selectedPath == file.path
                    && state.position == nil ? state.navigation : nil,
                    centered: false, topInset: 34).frame(width: 1, height: 1)
                }
            } header: {
              PullRequestCodeFileHeader(file: file, state: state)
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
          .background { PullRequestCodeScrollPosition(state: state).frame(width: 0, height: 0) }
      }
      .task(id: state.navigation) {
        guard state.navigationPending, let path = state.selectedPath,
          state.files.contains(where: { $0.path == path }) else { return }
        // Materialize an offscreen section. Native anchors then address the page's
        // vertical document without changing its nested horizontal code scroller.
        proxy.scrollTo(path, anchor: .top)
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
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
          .accessibilityHidden(true)
        TextField("筛选文件…", text: Binding(get: { state.query }, set: { state.query = $0 }))
          .textFieldStyle(.plain)
          .accessibilityLabel("筛选文件")
          .accessibilityIdentifier("pull-request-code-file-search")
        if !state.query.isEmpty {
          Button { state.query = "" } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("清除文件筛选")
          .accessibilityIdentifier("pull-request-code-file-search-clear")
        }
      }
      .padding(.horizontal, 9).frame(height: 32)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
      .padding(.horizontal, 8).padding(.top, 8)
      ScrollView {
        if state.filteredFiles.isEmpty {
          Text("没有匹配的文件").foregroundStyle(.secondary).padding(8)
        } else {
          TaskPullRequestCodeTreeView(nodes: GitHubPRCodeTreeNode.tree(state.filteredFiles), state: state,
            count: { threads(for: $0).count })
        }
      }
    }.frame(maxHeight: .infinity, alignment: .top)
      .accessibilityIdentifier("pull-request-code-file-tree")
  }

  private func divider(width: CGFloat, totalWidth: CGFloat) -> some View {
    Rectangle().fill(.quaternary).frame(width: PullRequestCodeSplitLayout.dividerWidth).contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0).onChanged { value in
        if dragWidth == nil { dragWidth = width }
        leftSplitRatio = PullRequestCodeSplitLayout.leftRatio(
          forTreeWidth: (dragWidth ?? width) - value.translation.width, in: totalWidth)
      }.onEnded { _ in dragWidth = nil })
      .focusable().onKeyPress(.leftArrow) { resizeTree(to: width + 10, in: totalWidth); return .handled }
      .onKeyPress(.rightArrow) { resizeTree(to: width - 10, in: totalWidth); return .handled }
      .onKeyPress(.home) { resizeTree(to: .infinity, in: totalWidth); return .handled }
      .onKeyPress(.end) { resizeTree(to: 0, in: totalWidth); return .handled }
      .accessibilityLabel("文件树宽度").accessibilityValue("\(Int(width))")
      .accessibilityAdjustableAction { direction in
        resizeTree(to: width + (direction == .increment ? 10 : -10), in: totalWidth)
      }
  }

  private func resizeTree(to width: CGFloat, in totalWidth: CGFloat) {
    leftSplitRatio = PullRequestCodeSplitLayout.leftRatio(forTreeWidth: width, in: totalWidth)
  }
}
