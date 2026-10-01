import SwiftUI

struct VoicePickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedVoiceID: String
  @State private var customVoiceID: String
  @State private var customSelected: Bool
  @State private var preview = RealtimeVoicePreview()
  @FocusState private var customFocused: Bool
  let config: ModelConfiguration
  let realtimeModelID: String
  let onSave: (String) -> Void

  static let builtInVoices = [
    "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"
  ]

  init(selectedVoiceID: String, config: ModelConfiguration, realtimeModelID: String,
    onSave: @escaping (String) -> Void) {
    let isCustom = !Self.builtInVoices.contains(selectedVoiceID)
    _selectedVoiceID = State(initialValue: isCustom ? "" : selectedVoiceID)
    _customVoiceID = State(initialValue: isCustom ? selectedVoiceID : "")
    _customSelected = State(initialValue: isCustom)
    self.config = config
    self.realtimeModelID = realtimeModelID
    self.onSave = onSave
  }

  private var choice: String {
    (customSelected ? customVoiceID : selectedVoiceID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canPreview: Bool {
    !config.baseURL.isEmpty && !realtimeModelID.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("选择音色").appFont(size: 18, weight: .semibold)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(Self.builtInVoices, id: \.self) { voice in
            HStack(spacing: 8) {
              Button {
                selectedVoiceID = voice
                customSelected = false
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: customSelected || selectedVoiceID != voice
                    ? "circle" : "largecircle.fill.circle")
                    .frame(width: 18)
                  Text(voice.capitalized)
                  Spacer()
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("音色：\(voice)")
              .accessibilityAddTraits(!customSelected && selectedVoiceID == voice ? [.isSelected] : [])
              previewButton(for: voice)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
          }
          Divider().padding(.vertical, 4)
          Button {
            customSelected = true
            customFocused = true
          } label: {
            HStack(spacing: 12) {
              Image(systemName: customSelected ? "largecircle.fill.circle" : "circle")
                .frame(width: 18)
              Text("自定义音色 ID")
              Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(customSelected ? [.isSelected] : [])
          if customSelected {
            HStack {
              TextField("服务支持的音色 ID", text: $customVoiceID)
                .textFieldStyle(.roundedBorder)
                .focused($customFocused)
                .accessibilityLabel("自定义音色 ID")
              previewButton(for: customVoiceID.trimmingCharacters(in: .whitespacesAndNewlines))
            }.padding(.horizontal, 9)
          }
        }
      }
      if let error = preview.error {
        Text(error).appFont(.caption).foregroundStyle(.red)
          .textSelection(.enabled)
      }
      Text(canPreview ? "试听会调用独立语音服务，可能产生用量；点击完成后保存音色。"
        : "请先配置实时语音模型和独立 API 服务，再试听音色。")
        .appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消") { preview.stop(); dismiss() }
          .keyboardShortcut(.escape, modifiers: [])
        Button("完成") {
          guard !choice.isEmpty else { return }
          preview.stop()
          onSave(choice)
          dismiss()
        }
        .keyboardShortcut(.return, modifiers: [])
        .disabled(choice.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 390, height: 550)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("voice-picker-sheet")
    .onDisappear { preview.stop() }
  }

  private func previewButton(for voice: String) -> some View {
    let active = preview.activeVoiceID == voice
    return Button {
      preview.toggle(config: config, model: realtimeModelID, voice: voice)
    } label: {
      Image(systemName: active ? "stop.fill" : "play.fill")
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.plain)
    .disabled(!canPreview || voice.isEmpty)
    .help(active ? "停止试听" : "试听 \(voice.capitalized)")
    .accessibilityLabel(active ? "停止试听 \(voice)" : "试听 \(voice)")
  }
}
