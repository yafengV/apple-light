import SwiftUI

/// Like the public dictionary component, the draft is separate from preferences
/// and row identity follows its index. Enter skips only the ensuing blur.
struct VoiceDictionarySettingsCard: View {
  @Bindable var store: WorkspaceStore
  @State private var draft: [String]?
  @State private var skipNextBlur = false
  @FocusState private var focusedRow: Int?
  private static let placeholders = ["Jane Doe", "Acme Widget", "checkout-form.tsx", "useCartState"]

  private var rows: [String] {
    let values = draft ?? store.voicePreferences.dictationDictionary
    return values.isEmpty ? [""] : values
  }

  var body: some View {
    AppearanceSettingsCard {
      SettingsLabeledRow {
        SettingsControlLabel(title: "听写词典",
          description: "将专有名词或短语加入设备端识别请求，帮助听写识别。")
      } control: {
        VoiceDictionaryActionButton(title: "添加词条", label: "添加词条", identifier: "voice-dictionary-add") { insert(after: nil) }
          .fixedSize().settingsFocusReveal()
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      ForEach(rows.indices, id: \.self) { index in
        Rectangle().fill(store.appearance.resolvedColors["border"].color)
          .frame(height: 1).padding(.horizontal, 16).accessibilityHidden(true)
        HStack(spacing: 8) {
          TextField(Self.placeholders.indices.contains(index) ? Self.placeholders[index] : Self.placeholders[0], text: Binding(
            get: { rows.indices.contains(index) ? rows[index] : "" },
            set: { value in
              var values = rows
              guard values.indices.contains(index) else { return }
              values[index] = value; draft = values
            }))
            .focused($focusedRow, equals: index)
            .settingsFocusReveal(focused: focusedRow == index)
            .onSubmit { insert(after: index) }
            .accessibilityLabel("词典词条 \(index + 1)")
            .accessibilityIdentifier("voice-dictionary-entry-\(index)")
          VoiceDictionaryActionButton(label: "移除词条 \(index + 1)", identifier: "voice-dictionary-remove-\(index)",
            enabled: rows.count != 1 || !rows[index].isEmpty) {
            var values = rows
            guard values.indices.contains(index) else { return }
            values.remove(at: index); save(values)
          }.frame(width: 28, height: 28).settingsFocusReveal()
        }
        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 40)
      }
    }
    .settingsSearchTarget(.voiceDictionary)
    .onChange(of: focusedRow) { oldValue, newValue in
      guard oldValue != nil, oldValue != newValue else { return }
      if skipNextBlur { skipNextBlur = false }
      else { save(rows) }
    }
  }

  private func insert(after index: Int?) {
    var values = rows
    let insertion = index.map { min($0 + 1, values.count) } ?? values.count
    if index != nil { skipNextBlur = true }
    values.insert("", at: insertion); draft = values
    focusedRow = insertion
  }

  private func save(_ values: [String]) {
    var preferences = store.voicePreferences
    preferences.dictationDictionary = values
    preferences.normalize()
    if preferences != store.voicePreferences { store.voicePreferences = preferences }
    draft = nil
  }
}
