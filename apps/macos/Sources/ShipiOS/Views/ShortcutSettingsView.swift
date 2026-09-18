import SwiftUI

struct ShortcutSettingsView: View {
  let store: WorkspaceStore
  @State var editor = ShortcutSettingsState()
  @State private var numberShortcutError: String?
  @State private var linkShortcutError: String?

  private var showsLinkShortcut: Bool {
    editor.matchesExternalBrowserShortcut(store.shortcuts.externalBrowserLinkShortcut)
  }

  private var matches: [DesktopCommand] {
    DesktopCommand.all.filter { editor.matches($0, preferences: store.shortcuts) }
  }
  var body: some View {
    GeometryReader { geometry in
    ScrollViewReader { proxy in
      SettingsScrollPage(title: SettingsPage.shortcuts.title, pinsControls: true) {
        if store.shortcuts.hasCustomizations {
          Button("恢复全部默认") {
            editor.capture = nil
            store.requestShortcutReset()
          }.settingsSearchTarget(.shortcutReset)
        }
      } controls: {
        HStack(spacing: 8) {
          if editor.searchByKeys {
            ShortcutCapture(text: editor.query.isEmpty ? "按下要查找的快捷键" : editor.query,
              accessibilityLabel: "按键搜索录制", receive: editor.receiveSearch,
              activityChanged: captureActivity, onBlur: {})
              .frame(height: 28)
          } else {
            TextField("搜索快捷键…", text: $editor.query).textFieldStyle(.roundedBorder)
              .accessibilityLabel("搜索快捷键命令")
              .onExitCommand { editor.query = "" }
            if !editor.query.isEmpty {
              Button { editor.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
            }
          }
          Button { editor.toggleSearchMode() } label: {
            Image(systemName: "keyboard")
              .padding(5).background(editor.searchByKeys ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
          }.buttonStyle(.plain).help("按组合键搜索").accessibilityLabel("按组合键搜索")
            .accessibilityValue(editor.searchByKeys ? "已开启" : "已关闭")
        }.settingsSearchTarget(.shortcutSearch)
      } content: {
        numberShortcutPreference(contentWidth: geometry.size.width)
        if let error = store.shortcuts.loadError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新读取快捷键设置") { editor.capture = nil; store.shortcuts.reload() }
        }
        LazyVStack(spacing: 0) {
          if showsLinkShortcut { externalBrowserPreference(contentWidth: geometry.size.width) }
          ForEach(matches) { item in
            commandRow(item, contentWidth: geometry.size.width)
              .padding(.vertical, 12)
              .background(SettingsSearchHighlightView(token:
                store.destination == .settings && store.settingsPage == .shortcuts
                  && store.settingsSearchRequest?.result.commandID == item.id ? store.settingsSearchRequest?.token : nil))
              .id("shortcut:" + item.id)
            Divider()
          }
          if matches.isEmpty && !showsLinkShortcut {
            ContentUnavailableView("没有匹配的快捷键", systemImage: "keyboard")
          }
        }
      }
      .task(id: store.settingsSearchRequest?.token) {
        guard store.destination == .settings, store.settingsPage == .shortcuts,
          let request = store.settingsSearchRequest, request.result.page == .shortcuts else { return }
        editor.clearSearch()
        await Task.yield()
        guard !Task.isCancelled, store.settingsSearchRequest == request,
          store.destination == .settings, store.settingsPage == .shortcuts else { return }
        proxy.scrollTo(request.result.id, anchor: .center)
      }
    }
    }
    .onChange(of: store.settingsPage) { _, _ in editor.capture = nil; editor.searchByKeys = false }
    .onChange(of: store.destination) { _, _ in editor.capture = nil; editor.searchByKeys = false }
    .onChange(of: editor.query) { _, value in
      editor.capture = nil
      if !value.isEmpty { clearCommandTarget() }
    }
    .onChange(of: editor.searchByKeys) { _, value in if value { clearCommandTarget() } }
  }

  private func externalBrowserPreference(contentWidth: CGFloat) -> some View {
    let layout = contentWidth < 640
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return VStack(alignment: .leading, spacing: 0) {
      layout {
        VStack(alignment: .leading, spacing: 5) {
          Text("在默认浏览器中打开网页链接")
          Text("按住所选按键并点按网页链接，即可在系统默认浏览器中打开")
            .appFont(.caption).foregroundStyle(.secondary)
          if let linkShortcutError {
            Text(linkShortcutError).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          Picker("在默认浏览器中打开网页链接", selection: Binding(
            get: { store.shortcuts.externalBrowserLinkShortcut },
            set: { shortcut in
              editor.capture = nil
              do { try store.shortcuts.setExternalBrowserLinkShortcut(shortcut); linkShortcutError = nil }
              catch { linkShortcutError = "无法保存快捷键偏好：\(error.localizedDescription)" }
            })) {
              ForEach(ExternalBrowserLinkShortcut.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().fixedSize()
          Spacer(minLength: 0)
        }.frame(width: contentWidth >= 640 ? 384 : nil)
      }.padding(.vertical, 12).settingsSearchTarget(.shortcutExternalBrowser)
      Divider()
    }
  }

  private func numberShortcutPreference(contentWidth: CGFloat) -> some View {
    let tabs = store.shortcuts.primaryNumberShortcutTarget == .tabs
    let layout = contentWidth < 640
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
    return VStack(alignment: .leading, spacing: 8) {
      layout {
        VStack(alignment: .leading, spacing: 5) {
          Text("数字快捷键")
          Text(tabs ? "使用 ⌘1–9 切换标签，⌃1–9 切换聊天" : "使用 ⌘1–9 切换聊天，⌃1–9 切换标签")
            .appFont(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Picker("数字快捷键", selection: Binding(
          get: { store.shortcuts.primaryNumberShortcutTarget },
          set: { target in
            editor.capture = nil
            do { try store.shortcuts.setNumberShortcutTarget(target); numberShortcutError = nil }
            catch { numberShortcutError = "无法保存快捷键偏好：\(error.localizedDescription)" }
          })) {
            Text("⌘1–9 切换标签").tag(NumberShortcutTarget.tabs)
            Text("⌘1–9 切换聊天").tag(NumberShortcutTarget.sidebar)
          }.labelsHidden().fixedSize()
      }
      if store.shortcuts.hasNumberShortcutConflicts {
        Text("部分数字快捷键已分配给其他操作").appFont(.caption).foregroundStyle(.orange)
      }
      if let numberShortcutError {
        Text(numberShortcutError).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      Divider().padding(.top, 12)
    }.settingsSearchTarget(.shortcutNumbers)
  }

  private func commandRow(_ item: DesktopCommand, contentWidth: CGFloat) -> some View {
    let values = store.shortcuts.bindings(item.id)
    let session = editor.capture?.commandID == item.id ? editor.capture : nil
    let appending = session != nil && session?.original == nil && !values.isEmpty
    let rows: [ShortcutBinding?] = values.isEmpty ? [nil] : values.map(Optional.some) + (appending ? [nil] : [])
    let label = VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
        if let error = editor.errors[item.id] {
          Text(error).foregroundStyle(.red).appFont(.caption).textSelection(.enabled)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    let controls = VStack(alignment: .leading, spacing: 0) {
        ForEach(rows.indices, id: \.self) { index in
          if let session, session.original == rows[index] {
            captureRow(session, title: item.title)
          } else {
            bindingRow(rows[index], command: item, canReset: index == resetIndex(item, values: values))
          }
        }
      }
      .frame(width: contentWidth >= 640 ? 384 : nil, alignment: .leading)
      .frame(maxWidth: contentWidth < 640 ? .infinity : nil, alignment: .leading)
    let layout = contentWidth < 640
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    return layout { label; controls }
  }

  private func bindingRow(_ binding: ShortcutBinding?, command: DesktopCommand, canReset: Bool) -> some View {
    HStack(spacing: 4) {
      Text(binding?.display ?? "未设置").appFont(.callout, design: .monospaced)
        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
        .background(binding == nil ? Color.clear : Color.primary.opacity(0.05),
          in: RoundedRectangle(cornerRadius: 5))
      Button {
        let append = NSApp.currentEvent?.modifierFlags.contains(.shift) == true && binding != nil
        editor.begin(command.id, replacing: append ? nil : binding)
      } label: { Image(systemName: "pencil").frame(width: 24, height: 28) }
        .buttonStyle(.plain).accessibilityLabel("修改\(command.title)快捷键")
        .help("修改快捷键；按住 Shift 点按可添加另一个绑定")
        .contextMenu {
          Button("添加快捷键") { editor.begin(command.id, replacing: nil) }
            .disabled(store.shortcuts.bindings(command.id).count >= 6)
        }
      Spacer(minLength: 8)
      if let binding {
        Button {
          editor.change(command.id) { try store.shortcuts.replace(binding, with: nil, for: command.id) }
        } label: { Image(systemName: "xmark").frame(width: 24, height: 28) }
          .buttonStyle(.plain).accessibilityLabel("清除\(command.title)快捷键：\(binding.display)")
          .help("清除此快捷键")
      }
      if canReset {
        Button { editor.change(command.id) { try store.shortcuts.reset(command.id) } } label: {
          Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 28)
        }.buttonStyle(.plain).accessibilityLabel("恢复\(command.title)默认快捷键").help("恢复默认快捷键")
      }
    }.frame(minHeight: 32)
  }

  private func captureRow(_ session: ShortcutSettingsState.Capture, title: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        ShortcutCapture(text: "按下快捷键", accessibilityLabel: "录制\(title)快捷键",
          receive: { editor.receive($0, sessionID: session.id, preferences: store.shortcuts) },
          activityChanged: captureActivity, onBlur: { editor.cancel(session.id) })
          .frame(width: 144, height: 28).id(session.id)
        Button("取消") { editor.cancel(session.id) }.buttonStyle(.plain)
      }
      if let warning = session.warning { Text(warning).foregroundStyle(.orange).appFont(.caption) }
    }.padding(.vertical, 2)
  }
  private func resetIndex(_ command: DesktopCommand, values: [ShortcutBinding]) -> Int? {
    guard store.shortcuts.overrides[command.id] != nil else { return nil }
    let defaults = store.shortcuts.defaultBindings(command.id)
    return values.indices.first {
      !defaults.indices.contains($0) || values[$0] != defaults[$0]
    } ?? 0
  }
  private func captureActivity(_ active: Bool) {
    store.shortcutCaptureCount = max(0, store.shortcutCaptureCount + (active ? 1 : -1))
  }
  private func clearCommandTarget() {
    if store.settingsSearchRequest?.result.commandID != nil { store.settingsSearchRequest = nil }
  }
}
