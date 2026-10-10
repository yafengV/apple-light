import SwiftUI

struct ShortcutSettingsView: View {
  let store: WorkspaceStore
  @State var editor = ShortcutSettingsState()
  @FocusState private var resetFocus: Bool?
  @FocusState private var rowFocus: String?
  @State private var captureReturnTarget: String?
  @State private var captureFocusRequest = UUID()
  @State private var numberShortcutError: String?
  @State private var linkShortcutError: String?

  private var showsLinkShortcut: Bool {
    editor.matchesExternalBrowserShortcut(store.shortcuts.externalBrowserLinkShortcut)
  }

  private var matches: [DesktopCommand] {
    DesktopCommand.all.filter { editor.matches($0, preferences: store.shortcuts) }
  }
  private var dictationGroup: ShortcutDictationGroup { editor.dictationGroup(preferences: store.shortcuts) }
  private enum Row: Identifiable {
    case command(DesktopCommand), externalBrowser
    var id: String { switch self { case .command(let command): command.id; case .externalBrowser: "external-browser-link" } }
  }
  private var ordinaryRows: [Row] {
    var rows: [Row] = []
    let ordinaryIDs = Set(dictationGroup.ordinaryCommandIDs)
    let commands = matches.filter { ordinaryIDs.contains($0.id) }
    for command in commands {
      rows.append(.command(command))
      if command.id == "browser-new", showsLinkShortcut { rows.append(.externalBrowser) }
    }
    if showsLinkShortcut, !commands.contains(where: { $0.id == "browser-new" }) { rows.append(.externalBrowser) }
    return rows
  }
  var body: some View {
    GeometryReader { geometry in
    let searchCaptureID = editor.searchCaptureID
    let rows = ordinaryRows
    ScrollViewReader { proxy in
      SettingsScrollPage(title: SettingsPage.shortcuts.title, pinsControls: true) {
        if store.shortcuts.hasCustomizations {
          Button("恢复全部默认") {
            requestReset()
          }.settingsActionFocus($resetFocus, equals: true, activate: requestReset)
            .settingsSearchTarget(.shortcutReset)
        }
      } controls: {
        HStack(spacing: 8) {
          if editor.searchByKeys {
            ShortcutCapture(text: editor.query.isEmpty ? "按下要查找的快捷键" : editor.query,
              accessibilityLabel: "按键搜索录制", receive: editor.receiveSearch,
              activityChanged: captureActivity, onBlur: {}, receiveRegistered: { binding in
                editor.receiveSearch(binding, sessionID: searchCaptureID)
              })
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
        if editor.matchesNumberPreference(store.shortcuts.primaryNumberShortcutTarget) {
          AppearanceSettingsCard {
            numberShortcutPreference(contentWidth: geometry.size.width)
              .padding(.horizontal, SettingsCardLayout.rowHorizontalInset)
              .padding(.vertical, SettingsCardLayout.rowVerticalInset)
          }
        }
        if let error = store.shortcuts.loadError {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新读取快捷键设置") { editor.capture = nil; store.shortcuts.reload() }
        }
        if !rows.isEmpty {
          AppearanceSettingsCard {
            LazyVStack(spacing: 0) {
              ForEach(rows) { row in
                switch row {
                case .command(let item): presentedCommandRow(item, contentWidth: geometry.size.width)
                case .externalBrowser:
                  externalBrowserPreference(contentWidth: geometry.size.width)
                    .padding(.horizontal, SettingsCardLayout.rowHorizontalInset)
                    .padding(.vertical, SettingsCardLayout.rowVerticalInset)
                }
                if row.id != rows.last?.id { cardDivider }
              }
            }
          }
        }
        if dictationGroup.showsCard { dictationCard(contentWidth: geometry.size.width) }
        if matches.isEmpty && !showsLinkShortcut && !editor.matchesNumberPreference(store.shortcuts.primaryNumberShortcutTarget) {
          ContentUnavailableView("没有匹配的快捷键", systemImage: "keyboard")
        }
      }
      .onChange(of: editor.query) { _, value in
        invalidateCaptureFocus()
        editor.searchChanged(preferences: store.shortcuts)
        if !value.isEmpty { clearCommandTarget() }
        if store.destination == .settings, store.settingsPage == .shortcuts,
          store.settingsSearchRequest?.result.commandID == nil {
          proxy.scrollTo(SettingsPageLayout.topAnchorID, anchor: .top)
        }
      }
      .task(id: store.settingsSearchRequest?.token) {
        guard store.destination == .settings, store.settingsPage == .shortcuts,
          let request = store.settingsSearchRequest, request.result.page == .shortcuts else { return }
        editor.clearSearch()
        if request.result.commandID == ShortcutDictationGroup.toggleID { editor.dictationAdvancedExpanded = true }
        await Task.yield()
        guard !Task.isCancelled, store.settingsSearchRequest == request,
          store.destination == .settings, store.settingsPage == .shortcuts else { return }
        proxy.scrollTo(request.result.id, anchor: .center)
      }
    }
    }
    .onSettingsConfirmationDismissal(store.shortcutResetRequested, store: store, page: .shortcuts) {
      if store.shortcuts.hasCustomizations { resetFocus = true }
      else { store.settingsSearchFocusRequest = UUID() }
    }
    .onChange(of: store.settingsPage) { _, page in if page != .shortcuts { leavePage() } }
    .onChange(of: store.destination) { _, destination in if destination != .settings { leavePage() } }
    .onDisappear { leavePage() }
    .onChange(of: dictationGroup.showsCard) { _, shown in if !shown { editor.dictationGroupRemoved() } }
    .onChange(of: editor.searchByKeys) { _, value in
      invalidateCaptureFocus()
      if value { clearCommandTarget() }
    }
  }

  private var cardDivider: some View {
    Divider().padding(.horizontal, SettingsCardLayout.dividerInset).accessibilityHidden(true)
  }
  private func presentedCommandRow(_ item: DesktopCommand, contentWidth: CGFloat) -> some View {
    commandRow(item, contentWidth: contentWidth)
      .padding(.horizontal, SettingsCardLayout.rowHorizontalInset)
      .padding(.vertical, SettingsCardLayout.rowVerticalInset)
      .background(SettingsSearchHighlightView(token:
        store.destination == .settings && store.settingsPage == .shortcuts
          && store.settingsSearchRequest?.result.commandID == item.id ? store.settingsSearchRequest?.token : nil))
      .id("shortcut:" + item.id)
  }
  private func dictationCard(contentWidth: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      AppearanceSettingsCard {
        if dictationGroup.holdMatches, let hold = DesktopCommand.all.first(where: { $0.id == ShortcutDictationGroup.holdID }) {
          presentedCommandRow(hold, contentWidth: contentWidth)
        }
        if dictationGroup.holdMatches && (dictationGroup.showsSingleTap || dictationGroup.showsAdvanced) { cardDivider }
        if dictationGroup.showsSingleTap, let toggle = DesktopCommand.all.first(where: { $0.id == ShortcutDictationGroup.toggleID }) {
          presentedCommandRow(toggle, contentWidth: contentWidth)
        }
        if dictationGroup.showsSingleTap && dictationGroup.showsAdvanced { cardDivider }
        if dictationGroup.showsAdvanced {
          HStack {
            VoiceDictationAdvancedButton(expanded: editor.dictationAdvancedExpanded) { control in
              if editor.dictationAdvancedExpanded, editor.capture?.commandID == ShortcutDictationGroup.toggleID {
                control.window?.makeFirstResponder(control)
              }
              editor.setDictationExpanded(!editor.dictationAdvancedExpanded)
            }.fixedSize().settingsFocusReveal()
            Spacer(minLength: 0)
          }.padding(.horizontal, SettingsCardLayout.rowHorizontalInset).padding(.vertical, 8)
        }
      }
      Text("适用于任意应用。按 Esc 取消录音。")
        .appFont(size: SettingsRowTypography.descriptionSize).foregroundStyle(.secondary)
        .padding(.horizontal, 16)
    }
  }

  private func requestReset() {
    invalidateCaptureFocus()
    editor.capture = nil
    store.requestShortcutReset()
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
          SettingsMenuPicker("在默认浏览器中打开网页链接", selection: Binding(
            get: { store.shortcuts.externalBrowserLinkShortcut },
            set: { shortcut in
              editor.capture = nil
              do { try store.shortcuts.setExternalBrowserLinkShortcut(shortcut); linkShortcutError = nil }
              catch { linkShortcutError = "无法保存快捷键偏好：\(error.localizedDescription)" }
            }), options: ExternalBrowserLinkShortcut.allCases.map {
              SettingsMenuOption(value: $0, title: $0.title)
            }).labelsHidden().fixedSize()
          Spacer(minLength: 0)
        }.frame(width: contentWidth >= 640 ? 384 : nil)
      }.settingsSearchTarget(.shortcutExternalBrowser)
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
        SettingsMenuPicker("数字快捷键", selection: Binding(
          get: { store.shortcuts.primaryNumberShortcutTarget },
          set: { target in
            editor.capture = nil
            do { try store.shortcuts.setNumberShortcutTarget(target); numberShortcutError = nil }
            catch { numberShortcutError = "无法保存快捷键偏好：\(error.localizedDescription)" }
          }), options: [
            SettingsMenuOption(value: .tabs, title: "⌘1–9 切换标签"),
            SettingsMenuOption(value: .sidebar, title: "⌘1–9 切换聊天")
          ]).labelsHidden().fixedSize()
      }
      if store.shortcuts.hasNumberShortcutConflicts {
        Text("部分数字快捷键已分配给其他操作").appFont(.caption).foregroundStyle(.orange)
      }
      if let numberShortcutError {
        Text(numberShortcutError).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }.settingsSearchTarget(.shortcutNumbers)
  }

  private func commandRow(_ item: DesktopCommand, contentWidth: CGFloat) -> some View {
    let values = store.shortcuts.bindings(item.id)
    let session = editor.capture?.commandID == item.id ? editor.capture : nil
    let appending = session != nil && session?.original == nil && !values.isEmpty
    let rows: [ShortcutBinding?] = values.isEmpty ? [nil] : values.map(Optional.some) + (appending ? [nil] : [])
    let label = VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
        if let error = editor.errors[item.id] ?? store.shortcuts.registrationError(item.id) {
          Text(error).foregroundStyle(.red).appFont(.caption).textSelection(.enabled)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    let controls = VStack(alignment: .leading, spacing: 0) {
        ForEach(rows.indices, id: \.self) { index in
          if let session, session.original == rows[index] {
            captureRow(session, title: item.title)
          } else {
            bindingRow(rows[index], command: item, index: index,
              canReset: index == resetIndex(item, values: values))
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

  private func bindingRow(_ binding: ShortcutBinding?, command: DesktopCommand, index: Int,
    canReset: Bool) -> some View {
    let edit = { beginCapture(command, replacing: binding, index: index) }
    let focusID = "edit:\(command.id):\(index)"
    return HStack(spacing: 4) {
      Text(binding?.display ?? "未设置").appFont(.callout, design: .monospaced)
        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
        .background(binding == nil ? Color.clear : Color.primary.opacity(0.05),
          in: RoundedRectangle(cornerRadius: 5))
      Button(action: edit) { Image(systemName: "pencil").frame(width: 24, height: 28) }
        .buttonStyle(.plain).accessibilityLabel("修改\(command.title)快捷键")
        .settingsActionFocus($rowFocus, equals: focusID, activate: edit)
        .help(command.isOSGlobal ? "修改快捷键" : "修改快捷键；按住 Shift 点按可添加另一个绑定")
        .contextMenu {
          Button("添加快捷键") { beginCapture(command, replacing: nil, index: index) }
            .disabled(command.isOSGlobal || store.shortcuts.bindings(command.id).count >= 6)
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
          receive: { event in
            finishCapture(session) { editor.receive(event, sessionID: session.id, preferences: store.shortcuts) }
          },
          activityChanged: captureActivity, onBlur: { editor.cancel(session.id) }, receiveModifier: { event in
            finishCapture(session) { editor.receiveModifier(event, sessionID: session.id, preferences: store.shortcuts) }
          }, receiveRegistered: { binding in
            finishCapture(session) { editor.receive(binding, sessionID: session.id, preferences: store.shortcuts) }
          })
          .frame(width: 144, height: 28).id(session.id)
        VoiceShortcutActionButton(kind: .cancel, label: "取消录制\(title)快捷键",
          identifier: "shortcut-cancel-\(session.commandID)") {
            finishCapture(session) { editor.cancel(session.id) }
          }.fixedSize().settingsFocusReveal()
      }
      if let warning = session.warning { Text(warning).foregroundStyle(.orange).appFont(.caption) }
    }.padding(.vertical, 2)
  }
  private func resetIndex(_ command: DesktopCommand, values: [ShortcutBinding]) -> Int? {
    guard store.shortcuts.isCustomized(command.id) else { return nil }
    let defaults = store.shortcuts.defaultBindings(command.id)
    return values.indices.first {
      !defaults.indices.contains($0) || values[$0] != defaults[$0]
    } ?? 0
  }
  private func captureActivity(_ active: Bool) {
    store.shortcutCaptureCount = max(0, store.shortcutCaptureCount + (active ? 1 : -1))
  }

  private func beginCapture(_ command: DesktopCommand, replacing binding: ShortcutBinding?, index: Int) {
    invalidateCaptureFocus()
    rowFocus = nil
    captureReturnTarget = "edit:\(command.id):\(index)"
    let append = !command.isOSGlobal && NSApp.currentEvent?.modifierFlags.contains(.shift) == true && binding != nil
    editor.begin(command.id, replacing: append ? nil : binding)
  }

  private func finishCapture(_ session: ShortcutSettingsState.Capture, action: () -> Void) {
    guard editor.capture?.id == session.id else { return }
    action()
    guard editor.capture == nil, let target = captureReturnTarget,
      let window = NSApp.keyWindow, window.identifier?.rawValue == "main" else { return }
    let request = UUID(), query = editor.query, route = store.environmentSettingsNavigationRevision
    let workspaceSession = store.session
    captureFocusRequest = request
    captureReturnTarget = nil
    // The recorder must finish dismantling before the replacement edit button
    // can take focus. Blur alone does not schedule this restoration.
    DispatchQueue.main.async { [weak window] in
      guard captureFocusRequest == request, editor.capture == nil, editor.query == query,
        !editor.searchByKeys, store.destination == .settings, store.settingsPage == .shortcuts,
        store.environmentSettingsNavigationRevision == route, store.session == workspaceSession,
        !store.hasSettingsConfirmation, store.presentedOverlay == nil,
        store.appshotIntroRequest == nil, !store.libraryRecoveryBlocksInteraction,
        !store.shuttingDown, NSApp.isActive, let window, window.isKeyWindow, window.isVisible,
        window.attachedSheet == nil, NSApp.modalWindow == nil,
        !SettingsPopupMenuButton.hasOpenMenu(in: window) else { return }
      if let view = window.firstResponder as? NSView,
        view !== window.contentView, !(view is ShortcutCapture.Field) { return }
      rowFocus = target
    }
  }

  private func invalidateCaptureFocus() {
    captureFocusRequest = UUID()
    captureReturnTarget = nil
  }

  private func leavePage() {
    invalidateCaptureFocus()
    editor.leavePage()
  }
  private func clearCommandTarget() {
    if store.settingsSearchRequest?.result.commandID != nil { store.settingsSearchRequest = nil }
  }
}
