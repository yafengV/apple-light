import AVFoundation
import AppKit
import Speech
import SwiftUI

struct VoiceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var microphones: [AVCaptureDevice] = []
  @State private var shortcutPresentation: VoiceShortcutPresentation
  @State private var showingVoicePicker = false
  @State private var voicePickerPresentationID = UUID()
  @State private var dictationAdvancedExpanded = false
  @Environment(\.settingsSearchPresentation) private var searchRequest
  @Environment(\.appAppearance) private var appearance

  private typealias GlobalHotkeyMode = VoiceShortcutPresentation.Mode

  init(store: WorkspaceStore, shortcutPresentation: VoiceShortcutPresentation? = nil) {
    self.store = store
    _shortcutPresentation = State(initialValue: shortcutPresentation ?? VoiceShortcutPresentation())
  }

  private static let languages: [SettingsMenuOption<String?>] = {
    let supported = SFSpeechRecognizer.supportedLocales().filter {
      SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
    }.sorted {
      let left = Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
      let right = Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier
      return left.localizedStandardCompare(right) == .orderedAscending
    }
    return [SettingsMenuOption(value: nil, title: "跟随系统语言")] + supported.map { locale in
      SettingsMenuOption(value: Optional(locale.identifier),
        title: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
    }
  }()

  private var microphoneOptions: [SettingsMenuOption<String?>] {
    var options = [SettingsMenuOption(value: Optional<String>.none, title: "系统默认")]
    options += microphones.sorted {
      $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
    }.map { SettingsMenuOption(value: Optional($0.uniqueID), title: $0.localizedName) }
    if let selected = store.voicePreferences.microphoneDeviceID,
      !microphones.contains(where: { $0.uniqueID == selected }) {
      options.append(SettingsMenuOption(value: Optional(selected), title: "所选麦克风已断开", enabled: false))
    }
    return options
  }

  var body: some View {
    SettingsScrollPage(title: "语音", actions: {}, controls: {}) {
      generalSection
      voiceChatSection
      VStack(alignment: .leading, spacing: 6) {
        SettingsSection("听写") {
          globalHotkeyRow(.hold)
          if dictationAdvancedExpanded { globalHotkeyRow(.toggle) }
        }
        if let target = store.dictation.target, target.hasPrefix("global-dictation:") {
          SettingsSection {
            HStack {
              Label(store.dictation.phase == .finishing ? "正在整理听写…" : "正在全局听写",
                systemImage: "mic.fill")
              Spacer()
              Button("结束听写") { store.dictation.finish(target: target) }
                .disabled(store.dictation.phase == .finishing)
            }
          }
        }
        if let error = store.globalDictationHotkeyError {
          Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        recordingsCard
        if let error = store.voiceRecordingHistory.error {
          HStack(alignment: .top) {
            Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
            Spacer()
            Button("关闭") { store.voiceRecordingHistory.clearError() }
          }
        }
      }
      VoiceDictionarySettingsCard(store: store)
      Text("在输入区使用 \(store.shortcuts.label("dictation")) 开始或结束听写。")
        .appFont(.caption).foregroundStyle(.secondary)
    }
    .settingsFormStyle()
    .onAppear { refreshMicrophones() }
    .task(id: searchRequest?.token) {
      if searchRequest?.result.field == .voiceToggleHotkey { dictationAdvancedExpanded = true }
    }
    .onChange(of: store.settingsPage) { _, page in
      if page != .voice { resetShortcutPresentation() }
    }
    .onChange(of: store.destination) { _, destination in
      if destination != .settings { resetShortcutPresentation() }
    }
    .sheet(isPresented: $showingVoicePicker) {
      VoicePickerSheet(selectedVoiceID: store.voicePreferences.realtimeVoiceID,
        config: store.modelConfiguration,
        realtimeModelID: store.voicePreferences.realtimeModelID) { voiceID in
        var preferences = store.voicePreferences
        preferences.realtimeVoiceID = voiceID
        store.voicePreferences = preferences
      }
      .environment(\.appAppearance, store.appearance)
      .id(voicePickerPresentationID)
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
      refreshMicrophones()
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
      refreshMicrophones()
    }
    .onDisappear { resetShortcutPresentation() }
  }

  private var generalSection: some View {
    SettingsSection("通用") {
      SettingsMenuPicker("麦克风", description: "用于设备端听写。", selection: Binding(
        get: { store.voicePreferences.microphoneDeviceID },
        set: { value in
          var preferences = store.voicePreferences
          preferences.microphoneDeviceID = value
          store.voicePreferences = preferences
        }), options: microphoneOptions)
        .settingsSearchTarget(.voiceMicrophone)
      SettingsMenuPicker("语言", description: "用于设备端听写。", selection: Binding(
        get: { store.voicePreferences.dictationLocaleIdentifier },
        set: { value in
          var preferences = store.voicePreferences
          preferences.dictationLocaleIdentifier = value
          store.voicePreferences = preferences
        }), options: Self.languages)
        .settingsSearchTarget(.voiceLanguage)
    }
  }

  private var voiceChatSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSection("语音聊天") {
        if store.modelConfiguration.baseURL.isEmpty || store.voicePreferences.realtimeModelID.isEmpty {
          LabeledContent {
            Button("配置模型与 API") { store.openSettings(.model) }
          } label: {
            SettingsControlLabel(title: "语音聊天尚未配置",
              description: "先在“模型与 API”中配置独立服务和实时语音模型。")
          }
        }
        LabeledContent {
          Button {
            voicePickerPresentationID = UUID()
            showingVoicePicker = true
          } label: {
            HStack(spacing: 8) {
              Circle().fill(store.appearance.accentColor).frame(width: 12, height: 12)
                .accessibilityHidden(true)
              Text(store.voicePreferences.realtimeVoiceID.capitalized)
            }
          }
          .accessibilityLabel("选择音色：\(store.voicePreferences.realtimeVoiceID)")
        } label: {
          SettingsControlLabel(title: "音色", description: "选择新语音聊天使用的音色。")
        }
        .settingsSearchTarget(.voiceVoice)
        globalHotkeyRow(.voiceChat)
        Toggle(isOn: Binding(
          get: { store.voicePreferences.screenContextEnabled },
          set: { value in
            var preferences = store.voicePreferences
            preferences.screenContextEnabled = value
            store.voicePreferences = preferences
          })) {
          SettingsControlLabel(title: "屏幕上下文",
            description: "语音聊天中提到屏幕内容时，可读取前台应用。首次使用时由 macOS 请求权限。")
        }
        .settingsSearchTarget(.voiceScreenContext)
      }
      .settingsSearchTarget(.voiceChat)
      if let error = store.globalVoiceChatHotkeyError {
        Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
  }

  private var recordingsCard: some View {
    AppearanceSettingsCard {
      SettingsControlLabel(title: "最近录音", description: "最近 20 条录音保存在此设备。")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
      ForEach(store.voiceRecordingHistory.recordings) { recording in
        Rectangle().fill(store.appearance.resolvedColors["border"].color)
          .frame(height: 1).padding(.horizontal, 16).accessibilityHidden(true)
        VoiceRecordingSettingsRow(store: store, recording: recording) { download(recording.id) }
      }
    }
    .settingsSearchTarget(.voiceRecordings)
  }

  private func refreshMicrophones() {
    microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
      mediaType: .audio, position: .unspecified).devices
  }

  private func resetShortcutPresentation() {
    dictationAdvancedExpanded = false
    shortcutPresentation.reset()
    store.voiceShortcutRegistrationErrors.removeAll()
  }

  private func download(_ id: UUID) {
    guard let source = store.voiceRecordingHistory.recordingURL(for: id),
      let window = NSApp.keyWindow else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "听写录音-\(id.uuidString.prefix(8)).caf"
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let destination = panel.url else { return }
      do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
      catch { store.voiceRecordingHistory.report(error) }
    }
  }

  private func globalHotkeyRow(_ mode: GlobalHotkeyMode) -> some View {
    let captureID = shortcutPresentation.captureID
    let title: String
    let description: String
    let binding: ShortcutBinding?
    let searchField: SettingsSearchField
    switch mode {
    case .hold:
      title = "按住听写快捷键"
      description = "按住时在桌面当前输入框听写，松开后结束。"
      binding = store.voicePreferences.globalHoldHotkey
      searchField = .voiceHoldHotkey
    case .toggle:
      title = "单击听写快捷键"
      description = "按一次开始，再按一次结束。"
      binding = store.voicePreferences.globalToggleHotkey
      searchField = .voiceToggleHotkey
    case .voiceChat:
      title = "语音聊天快捷键"
      description = "在任意应用中按一次开始语音聊天，再按一次结束。"
      binding = store.voicePreferences.globalVoiceChatHotkey
      searchField = .voiceChatHotkey
    }
    return LabeledContent {
      HStack(spacing: 0) {
        if shortcutPresentation.recording == mode {
          HStack(spacing: 8) {
            ShortcutCapture(text: "按下快捷键", accessibilityLabel: "录制\(title)",
              receive: { receiveGlobalHotkey($0, mode: mode, captureID: captureID) },
              activityChanged: { active in
                store.shortcutCaptureCount = max(0,
                  store.shortcutCaptureCount + (active ? 1 : -1))
              }, onBlur: {
                shortcutPresentation.end(mode, id: captureID)
              }, receiveModifier: { event in
                guard shortcutPresentation.owns(mode, id: captureID),
                  let binding = shortcutPresentation.modifierCapture.flagsChanged(event.modifierFlags) else { return }
                saveGlobalHotkey(binding, mode: mode, captureID: captureID)
              }, receiveRegistered: { binding in
                saveGlobalHotkey(binding, mode: mode, captureID: captureID)
              })
              .frame(width: 144, height: 28)
            VoiceShortcutActionButton(kind: .cancel, label: "取消录制\(title)",
              identifier: "voice-hotkey-cancel-\(mode.rawValue)") {
                shortcutPresentation.end(mode, id: captureID)
              }.fixedSize().settingsFocusReveal()
          }
        } else {
          HStack(spacing: 4) {
            Text(binding?.display ?? "关闭").appFont(size: 13).lineLimit(1)
              .foregroundStyle(appearance.resolvedColors["textForegroundSecondary"].color)
              .padding(.horizontal, binding == nil ? 0 : 8)
              .padding(.vertical, binding == nil ? 0 : 4)
              .background(binding == nil ? Color.clear
                : appearance.resolvedColors["textForegroundSecondary"].color.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 6))
              .accessibilityLabel("\(title)：\(binding?.display ?? "关闭")")
            VoiceShortcutActionButton(kind: .edit,
              label: "\(binding == nil ? "设置" : "更改")\(title)",
              identifier: "voice-hotkey-edit-\(mode.rawValue)") {
                store.voiceShortcutRegistrationErrors[mode] = nil
                shortcutPresentation.begin(mode)
              }.fixedSize().settingsFocusReveal()
          }
          if binding != nil {
            VoiceShortcutActionButton(kind: .clear, label: "清除\(title)",
              identifier: "voice-hotkey-clear-\(mode.rawValue)") {
                clearGlobalHotkey(mode)
              }.fixedSize().settingsFocusReveal().padding(.leading, 8)
          }
        }
      }.frame(minHeight: 32)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        SettingsControlLabel(title: title, description: description)
        if mode == .hold {
          VoiceDictationAdvancedButton(expanded: dictationAdvancedExpanded) { control in
            if dictationAdvancedExpanded, shortcutPresentation.recording == .toggle {
              control.window?.makeFirstResponder(control)
              shortcutPresentation.end(.toggle, id: captureID)
            }
            dictationAdvancedExpanded.toggle()
          }.fixedSize().settingsFocusReveal()
        }
        if let warning = shortcutPresentation.warnings[mode] ?? store.voiceShortcutRegistrationErrors[mode] {
          Text(warning).appFont(size: SettingsRowTypography.descriptionSize).foregroundStyle(.red)
            .settingsTextLineHeight(text: warning, fontSize: SettingsRowTypography.descriptionSize,
              lineHeight: SettingsRowTypography.descriptionLineHeight)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .accessibilityIdentifier("voice-hotkey-error-\(mode.rawValue)")
        }
      }
    }
    .settingsSearchTarget(searchField)
  }

  private func clearGlobalHotkey(_ mode: GlobalHotkeyMode) {
    var preferences = store.voicePreferences
    switch mode {
    case .hold: preferences.globalHoldHotkey = nil
    case .toggle: preferences.globalToggleHotkey = nil
    case .voiceChat: preferences.globalVoiceChatHotkey = nil
    }
    store.voicePreferences = preferences
    shortcutPresentation.warnings[mode] = nil
  }

  private func receiveGlobalHotkey(_ event: NSEvent, mode: GlobalHotkeyMode, captureID: UUID?) {
    guard shortcutPresentation.owns(mode, id: captureID), !event.isARepeat else { return }
    shortcutPresentation.modifierCapture.reset()
    if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
      shortcutPresentation.end(mode, id: captureID)
      return
    }
    guard let binding = ShortcutBinding(event: event) else { return }
    saveGlobalHotkey(binding, mode: mode, captureID: captureID)
  }

  private func saveGlobalHotkey(_ binding: ShortcutBinding, mode: GlobalHotkeyMode, captureID: UUID?) {
    guard shortcutPresentation.end(mode, id: captureID) else { return }
    shortcutPresentation.warnings[mode] = nil
    if !binding.isBareModifier,
      let message = binding.validationMessage(for: "global-dictation") {
      shortcutPresentation.warnings[mode] = message
      return
    }
    if let conflict = store.shortcuts.conflict(for: binding, excluding: mode.commandID),
      !conflict.allowsBareModifiers {
      shortcutPresentation.warnings[mode] = "已用于“\(conflict.title)”，请先移除该绑定。"
      return
    }
    var preferences = store.voicePreferences
    let others: [(mode: GlobalHotkeyMode, title: String, binding: ShortcutBinding?)] = [
      (.hold, "按住听写", mode == .hold ? nil : preferences.globalHoldHotkey),
      (.toggle, "单击听写", mode == .toggle ? nil : preferences.globalToggleHotkey),
      (.voiceChat, "语音聊天", mode == .voiceChat ? nil : preferences.globalVoiceChatHotkey),
    ]
    if let conflict = others.first(where: { $0.binding == binding }) {
      shortcutPresentation.warnings[mode] = mode != .voiceChat && conflict.mode != .voiceChat
        ? "请为单击听写选择不同的快捷键。" : "已用于“\(conflict.title)”，请先移除该绑定。"
      return
    }
    if binding.isBareModifier,
      let conflict = others.first(where: { other in
        guard let existing = other.binding, existing.isBareModifier else { return false }
        return binding.modifierFlags.isSubset(of: existing.modifierFlags)
          || existing.modifierFlags.isSubset(of: binding.modifierFlags)
      }) {
      shortcutPresentation.warnings[mode] = "与“\(conflict.title)”的修饰键组合重叠，请选择不同组合。"
      return
    }
    switch mode {
    case .hold: preferences.globalHoldHotkey = binding
    case .toggle: preferences.globalToggleHotkey = binding
    case .voiceChat: preferences.globalVoiceChatHotkey = binding
    }
    if preferences == store.voicePreferences { store.retryVoiceHotkeyRegistration(mode) }
    else { store.voicePreferences = preferences }
  }
}
