import AppKit
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
  @State private var addressSuggestionsVisible = false
  @State private var addressSuggestionTabID: UUID?
  @State private var selectedAddressSuggestion = -1
  private var comments: [BrowserComment] { store.browserComments(taskID: context?.taskID) }
  private func canFocus() -> Bool {
    context?.canFocus() ?? (store.browserVisible && store.presentedOverlay == nil
      && !store.showingModelPicker && !store.showingBranchPicker)
  }
  private var displayedTab: BrowserTab? {
    if let tabID { return session.tabs.first { $0.id == tabID } }
    return session.selected
  }
  private func addressMatches(_ tab: BrowserTab) -> [BrowserHistoryEntry] {
    BrowserAddressInput.historyMatches(tab.address, in: store.library.browserHistory)
  }
  private func moveAddressSuggestion(_ direction: Int, tab: BrowserTab) {
    let count = addressMatches(tab).count
    guard count > 0 else { return }
    if selectedAddressSuggestion < 0 {
      selectedAddressSuggestion = direction < 0 ? count - 1 : 0
    } else {
      selectedAddressSuggestion = (selectedAddressSuggestion + direction + count) % count
    }
  }
  private func navigateAddress(_ text: String, tab: BrowserTab) {
    let matches = addressMatches(tab)
    if selectedAddressSuggestion >= 0, selectedAddressSuggestion < matches.count {
      tab.address = matches[selectedAddressSuggestion].url
    } else {
      do { tab.address = try BrowserAddressInput.url(text).absoluteString }
      catch { tab.address = text }
    }
    addressSuggestionsVisible = false
    selectedAddressSuggestion = -1
    tab.navigate()
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
        ZStack(alignment: .top) {
          VStack(spacing: 0) {
        HStack(spacing: 9) {
          Button { tab.back() } label: { Image(systemName: "chevron.left") }
            .disabled(!tab.canGoBack).help("后退").accessibilityLabel("浏览器后退")
          Button { tab.forward() } label: { Image(systemName: "chevron.right") }
            .disabled(!tab.canGoForward).help("前进").accessibilityLabel("浏览器前进")
          Button { if tab.loading { tab.stop() } else { tab.reload() } } label: {
            Image(systemName: tab.loading ? "xmark" : "arrow.clockwise")
          }.help(tab.loading ? "停止加载" : "重新加载").accessibilityLabel(tab.loading ? "停止加载" : "重新加载网页")
          BrowserAddressField(tab: tab, session: session, canFocus: canFocus,
            independentFocus: context?.independentFocus == true,
            onBeginEditing: {
              addressSuggestionTabID = tab.id
              addressSuggestionsVisible = true
              selectedAddressSuggestion = -1
            }, onEndEditing: {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if !tab.editingAddress { addressSuggestionsVisible = false }
              }
            }, onChange: { selectedAddressSuggestion = -1 },
            onMoveSuggestion: { moveAddressSuggestion($0, tab: tab) },
            onSubmit: { navigateAddress($0, tab: tab) },
            onCancel: { addressSuggestionsVisible = false })
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
            Button("添加整页截图到输入区") {
              Task { await store.captureBrowserSnapshot(tab, taskID: context?.taskID, fullPage: true) }
            }.disabled(tab.committedURL == nil || tab.loading || tab.selectingElement
              || tab.capturingSnapshot || store.importingImages || store.importingFiles)
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
        if tab.showingPageFind {
          BrowserPageFindBar(tab: tab)
          Divider()
        }
        if let reference = tab.selectedElement {
          BrowserElementReferenceView(store: store, tab: tab, reference: reference, context: context)
            .id(reference.url + reference.selector + reference.selectionKind)
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
          addressSuggestionOverlay(tab)
            .padding(.top, 42)
            .padding(.horizontal, 76)
            .zIndex(1)
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

  @ViewBuilder private func addressSuggestionOverlay(_ tab: BrowserTab) -> some View {
    if addressSuggestionsVisible && addressSuggestionTabID == tab.id {
      let matches = addressMatches(tab)
      if !matches.isEmpty || BrowserAddressInput.isSearchQuery(tab.address) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
            Button {
              selectedAddressSuggestion = index
              navigateAddress(entry.url, tab: tab)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                  Text(entry.url).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
              }.padding(.horizontal, 12).padding(.vertical, 6)
                .background(selectedAddressSuggestion == index ? Color.accentColor.opacity(0.15) : Color.clear)
            }.buttonStyle(.plain).accessibilityLabel("历史页面：\(entry.title.isEmpty ? entry.url : entry.title)")
          }
          if matches.isEmpty && BrowserAddressInput.isSearchQuery(tab.address) {
            Button { navigateAddress(tab.address, tab: tab) } label: {
              Label("搜索 Google：\(tab.address)", systemImage: "magnifyingglass")
                .lineLimit(1).padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
          }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
        .shadow(radius: 12, y: 5)
        .accessibilityIdentifier("browser-address-suggestions")
      }
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
  @State private var adjusting = false
  @State private var replacementText = ""
  @State private var fontFamily = ""
  @State private var useFontSize = false
  @State private var fontSize = 16
  @State private var usePadding = false
  @State private var padding = 8
  @State private var useLetterSpacing = false
  @State private var letterSpacing = 0
  @State private var useTextColor = false
  @State private var textColor = Color.black
  @State private var useBackgroundColor = false
  @State private var backgroundColor = Color.white
  @State private var styleError: String?
  @State private var previewing = false

  private var styleFeedback: BrowserStyleFeedback {
    BrowserStyleFeedback(
      replacementText: replacementText.isEmpty ? nil : replacementText,
      fontFamily: fontFamily.isEmpty ? nil : fontFamily,
      fontSize: useFontSize ? fontSize : nil,
      padding: usePadding ? padding : nil,
      letterSpacing: useLetterSpacing ? letterSpacing : nil,
      textColor: useTextColor ? Self.hex(textColor) : nil,
      backgroundColor: useBackgroundColor ? Self.hex(backgroundColor) : nil)
  }

  private static func hex(_ color: Color) -> String {
    let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
    func byte(_ value: CGFloat) -> Int { min(255, max(0, Int((value * 255).rounded()))) }
    return String(format: "#%02X%02X%02X",
      byte(converted.redComponent), byte(converted.greenComponent), byte(converted.blueComponent))
  }

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
          .disabled(previewing)
      }
      HStack(alignment: .top) {
        TextField("描述需要修改的内容…", text: $comment, axis: .vertical)
          .textFieldStyle(.roundedBorder).lineLimit(2...5).accessibilityLabel("浏览器评论")
        if reference.selectionKind == "element" {
          Button(adjusting ? "收起调整" : "调整样式") {
            adjusting.toggle()
            styleError = nil
            if !adjusting { tab.clearStylePreview() }
          }.accessibilityLabel("调整网页元素样式").disabled(previewing)
        }
      }
      if adjusting && reference.selectionKind == "element" {
        VStack(alignment: .leading, spacing: 8) {
          TextField("替换文字（可选）", text: $replacementText)
            .accessibilityLabel("预览替换文字")
            .onChange(of: replacementText) { _, value in
              if value.count > 500 { replacementText = String(value.prefix(500)) }
            }
          Picker("字体", selection: $fontFamily) {
            Text("保持原样").tag("")
            Text("系统无衬线").tag("system-ui")
            Text("衬线").tag("serif")
            Text("等宽").tag("monospace")
          }
          HStack {
            Toggle("字号", isOn: $useFontSize)
            Spacer()
            if useFontSize { Stepper("\(fontSize) px", value: $fontSize, in: 8...96) }
          }
          HStack {
            Toggle("内边距", isOn: $usePadding)
            Spacer()
            if usePadding { Stepper("\(padding) px", value: $padding, in: 0...96) }
          }
          HStack {
            Toggle("字距", isOn: $useLetterSpacing)
            Spacer()
            if useLetterSpacing { Stepper("\(letterSpacing) px", value: $letterSpacing, in: -8...24) }
          }
          HStack {
            Toggle("文字颜色", isOn: $useTextColor)
            Spacer()
            if useTextColor { ColorPicker("文字颜色", selection: $textColor).labelsHidden() }
          }
          HStack {
            Toggle("背景颜色", isOn: $useBackgroundColor)
            Spacer()
            if useBackgroundColor { ColorPicker("背景颜色", selection: $backgroundColor).labelsHidden() }
          }
          HStack {
            Button("在网页中预览") {
              let style = styleFeedback
              styleError = nil
              previewing = true
              Task {
                do { try await tab.previewStyle(style, for: reference) }
                catch { styleError = error.localizedDescription }
                previewing = false
              }
            }.disabled(styleFeedback.isEmpty || previewing)
            Button("恢复网页原样") { tab.clearStylePreview(); styleError = nil }
              .disabled(previewing)
          }
          if let styleError { Text(styleError).foregroundStyle(.red).textSelection(.enabled) }
          Text("预览仅临时改变当前网页；保存评论后网页会恢复，调整目标将随消息发送。")
            .appFont(.caption).foregroundStyle(.secondary)
        }.appFont(.caption)
      }
      HStack {
        Button("添加为引用") { store.addBrowserElementToDraft(reference, taskID: context?.taskID); context?.focusComposer() }
        Spacer()
        Button("保存评论") {
          store.addBrowserComment(reference, body: comment,
            styleFeedback: styleFeedback.isEmpty ? nil : styleFeedback,
            taskID: context?.taskID)
          tab.clearSelectedElement()
        }
        .buttonStyle(.borderedProminent)
        .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || previewing)
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
            if let style = comment.styleFeedback, !style.isEmpty {
              Text(style.summary).appFont(size: 10).foregroundStyle(.secondary).lineLimit(2)
            }
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
