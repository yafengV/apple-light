import SwiftUI

struct VoicePickerSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var selectedVoiceID: String
  @State private var customVoiceID: String
  @State private var customSelected: Bool
  @FocusState private var customFocused: Bool
  let onSave: (String) -> Void

  static let builtInVoices = [
    "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"
  ]

  init(selectedVoiceID: String, onSave: @escaping (String) -> Void) {
    let isCustom = !Self.builtInVoices.contains(selectedVoiceID)
    _selectedVoiceID = State(initialValue: isCustom ? "" : selectedVoiceID)
    _customVoiceID = State(initialValue: isCustom ? selectedVoiceID : "")
    _customSelected = State(initialValue: isCustom)
    self.onSave = onSave
  }

  private var choice: String {
    (customSelected ? customVoiceID : selectedVoiceID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("选择音色").appFont(size: 18, weight: .semibold)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(Self.builtInVoices, id: \.self) { voice in
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
              .padding(.horizontal, 9)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("音色：\(voice)")
            .accessibilityAddTraits(!customSelected && selectedVoiceID == voice ? [.isSelected] : [])
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
            TextField("服务支持的音色 ID", text: $customVoiceID)
              .textFieldStyle(.roundedBorder)
              .focused($customFocused)
              .padding(.horizontal, 9)
              .accessibilityLabel("自定义音色 ID")
          }
        }
      }
      Text("所选音色用于新语音会话；当前会话保持原音色。")
        .appFont(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.escape, modifiers: [])
        Button("完成") {
          guard !choice.isEmpty else { return }
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
  }
}
