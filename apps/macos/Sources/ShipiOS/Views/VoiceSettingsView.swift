import Speech
import SwiftUI

struct VoiceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var newWord = ""

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
          LabeledContent {
            Text("系统默认").foregroundStyle(.secondary)
          } label: {
            SettingsControlLabel(title: "麦克风",
              description: "听写使用 macOS 当前默认的输入设备。")
          }
          .settingsSearchTarget(.voiceMicrophone)
          .padding(16)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

        Text("听写").appFont(size: 15, weight: .semibold)
        VStack(alignment: .leading, spacing: 12) {
          SettingsControlLabel(title: "听写词典",
            description: "将专有名词或短语加入设备端识别请求，帮助听写识别。")
          ForEach(store.voicePreferences.dictationDictionary, id: \.self) { word in
            HStack {
              Text(word).textSelection(.enabled)
              Spacer()
              Button {
                var preferences = store.voicePreferences
                preferences.dictationDictionary.removeAll { $0 == word }
                store.voicePreferences = preferences
              } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .accessibilityLabel("移除词条：\(word)")
            }
          }
          HStack {
            TextField("添加词语或短语", text: $newWord)
              .onSubmit(addWord)
            Button("添加词条", action: addWord)
              .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || store.voicePreferences.dictationDictionary.count >= 100)
          }
          Text("在输入区使用 \(store.shortcuts.label("dictation")) 开始或结束听写。")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .settingsSearchTarget(.voiceDictionary)
      }
    }
  }

  private func addWord() {
    let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return }
    var preferences = store.voicePreferences
    preferences.dictationDictionary.append(word)
    preferences.normalize()
    store.voicePreferences = preferences
    newWord = ""
  }
}
