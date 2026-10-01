import AVFoundation
import Speech
import SwiftUI

struct VoiceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var dictionaryRows: [DictionaryRow] = []
  @State private var microphones: [AVCaptureDevice] = []
  @State private var recordingGlobalHotkey: GlobalHotkeyMode?
  @State private var globalHotkeyWarning: String?
  @FocusState private var focusedDictionaryRow: UUID?

  private enum GlobalHotkeyMode: Hashable { case hold, toggle }

  private struct DictionaryRow: Identifiable {
    let id = UUID()
    var text: String
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
      VStack(alignment: .leading, spacing: 18) {
        Text("语音聊天").appFont(size: 15, weight: .semibold)
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "waveform")
            .foregroundStyle(.secondary).frame(width: 20)
          VStack(alignment: .leading, spacing: 4) {
            Text("语音聊天不可用").appFont(size: 13, weight: .medium)
            Text("当前配置支持设备端听写；实时语音会话尚不可用。")
              .appFont(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .settingsSearchTarget(.voiceChat)

        Text("通用").appFont(size: 15, weight: .semibold)
        VStack(spacing: 0) {
          SettingsMenuPicker("语言", description: "用于设备端听写。", selection: Binding(
            get: { store.voicePreferences.dictationLocaleIdentifier },
            set: { value in
              var preferences = store.voicePreferences
              preferences.dictationLocaleIdentifier = value
              store.voicePreferences = preferences
            }), options: Self.languages)
            .settingsSearchTarget(.voiceLanguage)
            .padding(16)
          Divider().padding(.horizontal, 16)
          SettingsMenuPicker("麦克风", description: "用于设备端听写。", selection: Binding(
            get: { store.voicePreferences.microphoneDeviceID },
            set: { value in
              var preferences = store.voicePreferences
              preferences.microphoneDeviceID = value
              store.voicePreferences = preferences
            }), options: microphoneOptions)
            .settingsSearchTarget(.voiceMicrophone)
            .padding(16)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

        Text("听写").appFont(size: 15, weight: .semibold)
        VStack(spacing: 0) {
          globalHotkeyRow(.hold)
          Divider().padding(.horizontal, 16)
          globalHotkeyRow(.toggle)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        if let target = store.dictation.target, target.hasPrefix("global-dictation:") {
          HStack {
            Label(store.dictation.phase == .finishing ? "正在整理听写…" : "正在全局听写",
              systemImage: "mic.fill")
            Spacer()
            Button("结束听写") { store.dictation.finish(target: target) }
              .disabled(store.dictation.phase == .finishing)
          }
          .padding(12)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        if let error = globalHotkeyWarning ?? store.globalDictationHotkeyError {
          Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        VStack(spacing: 0) {
          LabeledContent {
            Button("添加词条") { insertDictionaryRow(after: nil) }
          } label: {
            SettingsControlLabel(title: "听写词典",
              description: "将专有名词或短语加入设备端识别请求，帮助听写识别。")
          }
          .padding(16)
          ForEach(dictionaryRows) { row in
            Divider().padding(.horizontal, 16)
            HStack(spacing: 8) {
              TextField("词语或短语", text: Binding(
                get: { dictionaryRows.first(where: { $0.id == row.id })?.text ?? "" },
                set: { value in
                  guard let index = dictionaryRows.firstIndex(where: { $0.id == row.id }) else { return }
                  dictionaryRows[index].text = value
                }))
                .focused($focusedDictionaryRow, equals: row.id)
                .onSubmit { insertDictionaryRow(after: row.id) }
                .accessibilityLabel("词典词条")
              Button {
                dictionaryRows.removeAll { $0.id == row.id }
                if dictionaryRows.isEmpty { dictionaryRows = [DictionaryRow(text: "")] }
                persistDictionaryRows()
              } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .disabled(dictionaryRows.count == 1 && row.text.isEmpty)
                .accessibilityLabel("移除词条：\(row.text.isEmpty ? "空白" : row.text)")
            }
            .padding(.leading, 32)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .settingsSearchTarget(.voiceDictionary)
        Text("在输入区使用 \(store.shortcuts.label("dictation")) 开始或结束听写。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear { loadDictionaryRows(); refreshMicrophones() }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
      refreshMicrophones()
    }
    .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
      refreshMicrophones()
    }
    .onDisappear { persistDictionaryRows() }
    .onDisappear { recordingGlobalHotkey = nil }
    .onChange(of: focusedDictionaryRow) { oldValue, newValue in
      if oldValue != nil && oldValue != newValue {
        persistDictionaryRows()
        if newValue == nil { loadDictionaryRows() }
      }
    }
  }

  private func loadDictionaryRows() {
    dictionaryRows = store.voicePreferences.dictationDictionary.map { DictionaryRow(text: $0) }
    if dictionaryRows.isEmpty { dictionaryRows = [DictionaryRow(text: "")] }
  }

  private func insertDictionaryRow(after id: UUID?) {
    let row = DictionaryRow(text: "")
    if let id, let index = dictionaryRows.firstIndex(where: { $0.id == id }) {
      dictionaryRows.insert(row, at: index + 1)
    } else {
      dictionaryRows.append(row)
    }
    focusedDictionaryRow = row.id
  }

  private func persistDictionaryRows() {
    var preferences = store.voicePreferences
    preferences.dictationDictionary = dictionaryRows.map(\.text)
    preferences.normalize()
    if preferences != store.voicePreferences { store.voicePreferences = preferences }
  }

  private func refreshMicrophones() {
    microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
      mediaType: .audio, position: .unspecified).devices
  }

  private func globalHotkeyRow(_ mode: GlobalHotkeyMode) -> some View {
    let title = mode == .hold ? "按住听写快捷键" : "切换听写快捷键"
    let description = mode == .hold
      ? "按住时在桌面当前输入框听写，松开后结束。"
      : "在桌面当前输入框按一次开始听写，再按一次结束。"
    let binding = mode == .hold
      ? store.voicePreferences.globalHoldHotkey : store.voicePreferences.globalToggleHotkey
    return LabeledContent {
      HStack(spacing: 8) {
        if recordingGlobalHotkey == mode {
          ShortcutCapture(text: "按下快捷键", accessibilityLabel: "录制\(title)",
            receive: { receiveGlobalHotkey($0, mode: mode) },
            activityChanged: { active in
              store.shortcutCaptureCount = max(0,
                store.shortcutCaptureCount + (active ? 1 : -1))
            }, onBlur: { recordingGlobalHotkey = nil })
            .frame(width: 144, height: 28)
        } else {
          Button(binding?.display ?? "关闭") {
            globalHotkeyWarning = nil
            recordingGlobalHotkey = mode
          }
        }
        if binding != nil {
          Button {
            var preferences = store.voicePreferences
            if mode == .hold { preferences.globalHoldHotkey = nil }
            else { preferences.globalToggleHotkey = nil }
            store.voicePreferences = preferences
            recordingGlobalHotkey = nil
          } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭\(title)")
        }
      }
    } label: {
      SettingsControlLabel(title: title, description: description)
    }
    .padding(16)
    .settingsSearchTarget(mode == .hold ? .voiceHoldHotkey : .voiceToggleHotkey)
  }

  private func receiveGlobalHotkey(_ event: NSEvent, mode: GlobalHotkeyMode) {
    if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
      recordingGlobalHotkey = nil
      return
    }
    guard let binding = ShortcutBinding(event: event) else { return }
    if let message = binding.validationMessage(for: "global-dictation") {
      globalHotkeyWarning = message
      return
    }
    if let conflict = store.shortcuts.conflict(for: binding, excluding: "global-dictation") {
      globalHotkeyWarning = "已用于“\(conflict.title)”，请先移除该绑定。"
      return
    }
    var preferences = store.voicePreferences
    let other = mode == .hold ? preferences.globalToggleHotkey : preferences.globalHoldHotkey
    if other == binding {
      globalHotkeyWarning = "按住听写和切换听写不能使用同一个快捷键。"
      return
    }
    if mode == .hold { preferences.globalHoldHotkey = binding }
    else { preferences.globalToggleHotkey = binding }
    store.voicePreferences = preferences
    recordingGlobalHotkey = nil
    globalHotkeyWarning = nil
  }
}
