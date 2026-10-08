import SwiftUI

/// A persistent label is independent of the input's placeholder and value.
/// The same label remains visible in standalone and embedded settings cards.
struct SettingsTextField: View {
  let title: String
  @Binding var text: String
  var prompt: Text? = nil
  @FocusState private var focused: Bool

  init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
    self.title = title; _text = text; self.prompt = prompt
  }

  var body: some View {
    LabeledContent {
      TextField(title, text: $text, prompt: prompt)
        .focused($focused).settingsFocusReveal(focused: focused)
        .textFieldStyle(.roundedBorder).labelsHidden()
        .frame(minWidth: 0, idealWidth: 320, maxWidth: 320).accessibilityLabel(title)
    } label: {
      Text(title).appFont(size: SettingsRowTypography.labelSize, weight: .medium)
        .settingsTextLineHeight(text: title, fontSize: SettingsRowTypography.labelSize,
          lineHeight: SettingsRowTypography.labelLineHeight, weight: .medium)
    }
  }
}

struct SettingsSecureField: View {
  let title: String
  @Binding var text: String
  var prompt: Text? = nil
  @FocusState private var focused: Bool

  init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
    self.title = title; _text = text; self.prompt = prompt
  }

  var body: some View {
    LabeledContent {
      SecureField(title, text: $text, prompt: prompt)
        .focused($focused).settingsFocusReveal(focused: focused)
        .textFieldStyle(.roundedBorder).labelsHidden()
        .frame(minWidth: 0, idealWidth: 320, maxWidth: 320).accessibilityLabel(title)
    } label: {
      Text(title).appFont(size: SettingsRowTypography.labelSize, weight: .medium)
        .settingsTextLineHeight(text: title, fontSize: SettingsRowTypography.labelSize,
          lineHeight: SettingsRowTypography.labelLineHeight, weight: .medium)
    }
  }
}
