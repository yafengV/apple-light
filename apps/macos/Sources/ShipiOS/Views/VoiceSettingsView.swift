import Speech
import SwiftUI

struct VoiceSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var dictionaryRows: [DictionaryRow] = []
  @FocusState private var focusedDictionaryRow: UUID?

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
    .onAppear { loadDictionaryRows() }
    .onDisappear { persistDictionaryRows() }
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
}
