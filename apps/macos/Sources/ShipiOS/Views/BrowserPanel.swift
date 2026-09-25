import SwiftUI
import WebKit

struct BrowserHost: NSViewRepresentable {
  let tab: BrowserTab
  let session: BrowserSession
  let canFocus: () -> Bool
  var independentFocus = false
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView { tab.view }
  func updateNSView(_ view: WKWebView, context: Context) {
    let request = session.contentFocus
    guard session.contentFocusTarget == tab.id, context.coordinator.handled != request else { return }
    context.coordinator.handled = request
    DispatchQueue.main.async {
      guard canFocus(), (independentFocus || session.selection == tab.id), session.contentFocusTarget == tab.id,
        session.contentFocus == request, !tab.closed, let window = view.window,
        window.isKeyWindow, window.attachedSheet == nil else { return }
      window.makeFirstResponder(view)
    }
  }
  final class Coordinator { var handled: UUID? }
}

struct BrowserPanel: View {
  @Bindable var store: WorkspaceStore
  @Bindable var session: BrowserSession
  var context: BrowserPanelContext? = nil
  var showsTabStrip = true
  var tabID: UUID? = nil
  @State private var showingDownloads = false
  private var comments: [BrowserComment] { store.browserComments(taskID: context?.taskID) }
  private func canFocus() -> Bool {
    context?.canFocus() ?? (store.browserVisible && store.presentedOverlay == nil
      && !store.showingModelPicker && !store.showingBranchPicker)
  }
  private var displayedTab: BrowserTab? {
    if let tabID { return session.tabs.first { $0.id == tabID } }
    return session.selected
  }
  var body: some View {
    VStack(spacing: 0) {
      if showsTabStrip {
        HStack(spacing: 4) {
          ScrollViewReader { proxy in
            ScrollView(.horizontal) {
              HStack(spacing: 2) {
                ForEach(session.tabs) { tab in
                  BrowserTabChip(store: store, session: session, tab: tab, context: context).id(tab.id)
                }
              }
            }.scrollIndicators(.hidden)
              .onChange(of: session.selection) { _, id in if let id { proxy.scrollTo(id) } }
          }
          Button { if let context { context.newTab() } else { store.newBrowserTab() } } label: { Image(systemName: "plus") }
            .buttonStyle(.plain).help("新建浏览器标签 \(store.shortcuts.label("browser-new"))")
            .accessibilityLabel("新建浏览器标签").padding(8)
        }.appFont(.caption).padding(5)
        Divider()
      }
      if let tab = displayedTab {
        HStack(spacing: 9) {
          Button { tab.back() } label: { Image(systemName: "chevron.left") }
            .disabled(!tab.canGoBack).help("后退").accessibilityLabel("浏览器后退")
          Button { tab.forward() } label: { Image(systemName: "chevron.right") }
            .disabled(!tab.canGoForward).help("前进").accessibilityLabel("浏览器前进")
          Button { if tab.loading { tab.stop() } else { tab.reload() } } label: {
            Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
          }.help(tab.loading ? "停止加载" : "重新加载").accessibilityLabel(tab.loading ? "停止加载" : "重新加载网页")
          BrowserAddressField(tab: tab, session: session, canFocus: canFocus, independentFocus: context?.independentFocus == true)
            .frame(minWidth: 90, minHeight: 24).id(tab.id)
          Button {
            Task { await store.captureBrowserSnapshot(tab, taskID: context?.taskID) }
          } label: {
            if tab.capturingSnapshot { ProgressView().controlSize(.mini) }
            else { Image(systemName: "camera") }
          }
          .disabled(tab.committedURL == nil || tab.loading || tab.selectingElement
            || tab.capturingSnapshot || store.importingImages || store.importingFiles)
          .help("添加网页截图到输入区")
          .accessibilityLabel(tab.capturingSnapshot ? "正在生成网页截图" : "添加网页截图到输入区")
          Button { showingDownloads.toggle() } label: {
            Image(systemName: "arrow.down.circle")
              .overlay(alignment: .topTrailing) {
                let count = store.browserDownloads.filter {
                  $0.status == .preparing || $0.status == .downloading
                }.count
                if count > 0 {
                  Text("\(count)").appFont(size: 7, weight: .bold).foregroundStyle(.white)
                    .frame(minWidth: 11, minHeight: 11).background(.tint, in: Circle())
                    .offset(x: 5, y: -5)
                }
              }
          }.help("显示下载").accessibilityLabel("显示下载")
          if tab.selectingElement {
            Button { tab.cancelElementSelection() } label: { Image(systemName: "xmark.circle.fill") }
              .help("取消选择网页元素 Esc").accessibilityLabel("取消选择网页元素")
              .keyboardShortcut(.escape, modifiers: [])
          } else {
            Button { Task { await tab.selectElement() } } label: { Image(systemName: "scope") }
              .disabled(tab.committedURL == nil || tab.loading)
              .help("选择网页元素").accessibilityLabel("选择网页元素")
          }
          Menu {
            Button("复制网址") { session.copyURL(tabID: tab.id) }.disabled(tab.committedURL == nil)
            Button("忽略缓存重新加载") { tab.reload(bypassCache: true) }
            Button("重新打开关闭的标签页") { if let context { context.reopen() } else { store.reopenClosedBrowserTab() } }
              .disabled(!(context?.canReopen ?? session.canReopenClosedTab))
            if let url = tab.committedURL {
              Button("在系统浏览器中打开") { NSWorkspace.shared.open(url) }
            }
          } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }.buttonStyle(.plain).padding(10)
        if let error = tab.error {
          HStack(alignment: .top) {
            Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("重试") { tab.navigate() }.controlSize(.small)
          }.padding(10)
        }
        if let error = tab.elementSelectionError {
          HStack {
            Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("关闭") { tab.clearSelectedElement() }.controlSize(.small)
          }.padding(10)
        }
        if let error = tab.snapshotError {
          HStack {
            Text(error).appFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
            Spacer()
            Button("关闭") { tab.clearSnapshotError() }.controlSize(.small)
          }.padding(10)
        }
        if let reference = tab.selectedElement {
          BrowserElementReferenceView(store: store, tab: tab, reference: reference, context: context)
        } else if tab.selectingElement {
          Label("单击元素或拖动选择区域，按 Esc 取消", systemImage: "scope")
            .appFont(.caption).foregroundStyle(.secondary).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !comments.isEmpty {
          BrowserCommentsPanel(store: store, taskID: context?.taskID)
        }
        if showingDownloads {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Label("下载", systemImage: "arrow.down.circle")
                .appFont(.caption, weight: .medium)
              Spacer()
              Button("下载设置…") { if let context { context.openSettings() } else { store.openSettings(.browser) } }.controlSize(.small)
              Button { showingDownloads = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("关闭下载列表")
            }.padding(.horizontal, 8).padding(.top, 8)
            ScrollView { BrowserDownloadList(store: store, compact: true) }
              .frame(maxHeight: 220)
          }.background(Color.primary.opacity(0.035))
        }
        Divider()
        BrowserHost(tab: tab, session: session, canFocus: canFocus, independentFocus: context?.independentFocus == true).id(tab.id)
          .task(id: markerKey(tab: tab)) { await tab.renderCommentMarkers(comments) }
          .overlay {
          if tab.committedURL == nil && !tab.loading && tab.error == nil {
            ContentUnavailableView("打开网页", systemImage: "globe", description: Text("输入网址，或打开本地开发服务。"))
              .allowsHitTesting(false)
          }
        }
      }
    }.background {
      if context == nil { BrowserKeyboardBridge(store: store).frame(width: 0, height: 0) }
    }
      .onAppear {
        // Explicit content panes can appear in the background. Their layout
        // owner selects and focuses tabs in response to user actions.
        if tabID == nil { session.ensureTab() }
      }
  }

  private func markerKey(tab: BrowserTab) -> String {
    ([tab.committedURL?.absoluteString ?? ""] + comments.map {
      "\($0.id.uuidString):\($0.body):\($0.reference.url)"
    }).joined(separator: "|")
  }
}

private struct BrowserTabChip: View {
  @Bindable var store: WorkspaceStore
  @Bindable var session: BrowserSession
  @Bindable var tab: BrowserTab
  var context: BrowserPanelContext? = nil
  @State private var chipWidth: CGFloat = 0
  @State private var dragOffset: CGFloat = 0

  var body: some View {
    HStack(spacing: 5) {
      Button { session.select(tab.id) } label: {
        HStack(spacing: 5) {
          if tab.loading { ProgressView().controlSize(.mini) }
          Text(tab.title).lineLimit(1).frame(maxWidth: 120)
        }
      }.buttonStyle(.plain).help(tab.committedURL?.absoluteString ?? tab.title)
        .accessibilityAddTraits(session.selection == tab.id ? .isSelected : [])
      Button { if let context { context.closeTab(tab.id) } else { store.closeBrowserTab(tab.id) } } label: {
        Image(systemName: "xmark").appFont(size: 9)
      }
      .buttonStyle(.plain).accessibilityLabel("关闭标签：\(tab.title)")
    }
    .padding(8)
    .background(
      session.selection == tab.id ? Color.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: 6))
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { chipWidth = geometry.size.width }
          .onChange(of: geometry.size.width) { _, width in chipWidth = width }
      }
    }
    .offset(x: dragOffset)
    .zIndex(dragOffset == 0 ? 0 : 1)
    .simultaneousGesture(
      DragGesture(minimumDistance: 6)
        .onChanged { dragOffset = $0.translation.width }
        .onEnded { value in
          _ = session.reorderTab(tab.id, horizontalTranslation: value.translation.width,
            sourceWidth: chipWidth)
          withAnimation(.easeOut(duration: 0.12)) { dragOffset = 0 }
        })
    .contextMenu {
      Button("关闭标签页") { if let context { context.closeTab(tab.id) } else { store.closeBrowserTab(tab.id) } }
      Button("关闭其他标签页") { session.closeOtherTabs(keeping: tab.id) }
        .disabled(session.tabs.count <= 1)
      Button("关闭右侧标签页") { session.closeTabsToRight(of: tab.id) }
        .disabled(!session.canCloseTabsToRight(of: tab.id))
      Divider()
      Button("重新打开关闭的标签页") { if let context { context.reopen() } else { store.reopenClosedBrowserTab() } }
        .disabled(!(context?.canReopen ?? session.canReopenClosedTab))
    }
  }
}

private struct BrowserElementReferenceView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var tab: BrowserTab
  let reference: BrowserElementReference
  var context: BrowserPanelContext? = nil
  @State private var comment = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: reference.selectionKind == "region" ? "rectangle.dashed" : "scope")
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text(reference.selectionKind == "region" ? "选中区域" : reference.title)
            .appFont(.caption, weight: .medium).lineLimit(2)
          Text(reference.selector).appFont(size: 10, design: .monospaced)
            .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
        Spacer(minLength: 8)
        Button { tab.clearSelectedElement() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("取消网页批注").accessibilityLabel("取消网页批注")
      }
      TextField("描述需要修改的内容…", text: $comment, axis: .vertical)
        .textFieldStyle(.roundedBorder).lineLimit(2...5).accessibilityLabel("浏览器评论")
      HStack {
        Button("添加为引用") { store.addBrowserElementToDraft(reference, taskID: context?.taskID); context?.focusComposer() }
        Spacer()
        Button("保存评论") {
          store.addBrowserComment(reference, body: comment, taskID: context?.taskID)
          tab.clearSelectedElement()
        }
        .buttonStyle(.borderedProminent)
        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.controlSize(.small)
    }
    .padding(10).background(Color.accentColor.opacity(0.06))
  }
}

private struct BrowserCommentsPanel: View {
  @Bindable var store: WorkspaceStore
  var taskID: String? = nil
  private var comments: [BrowserComment] { store.browserComments(taskID: taskID) }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("\(comments.count) 条浏览器评论", systemImage: "text.bubble")
        .appFont(.caption, weight: .medium)
      ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
        HStack(alignment: .top, spacing: 8) {
          Text("\(index + 1)").appFont(.caption, weight: .semibold)
            .foregroundStyle(.white).frame(width: 20, height: 20)
            .background(Color.accentColor, in: Circle())
          VStack(alignment: .leading, spacing: 2) {
            Text(comment.body).appFont(.caption).lineLimit(3).textSelection(.enabled)
            Text(comment.reference.pageTitle.isEmpty ? comment.reference.url : comment.reference.pageTitle)
              .appFont(size: 10).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 4)
          Button {
            store.removeBrowserComment(comment.id, taskID: taskID)
          } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("移除浏览器评论").accessibilityLabel("移除浏览器评论 \(index + 1)")
        }
      }
    }
    .padding(10).background(Color.accentColor.opacity(0.04))
  }
}
