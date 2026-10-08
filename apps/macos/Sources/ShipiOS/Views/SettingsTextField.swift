import SwiftUI

/// A persistent label is independent of the input's placeholder and value.
/// This works in both the shared cards and the macOS 14 form fallback.
struct SettingsTextField: View {
  let title: String
  @Binding var text: String
  var prompt: Text? = nil

  init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
    self.title = title; _text = text; self.prompt = prompt
  }

  var body: some View {
    LabeledContent {
      TextField(title, text: $text, prompt: prompt)
        .textFieldStyle(.roundedBorder).labelsHidden()
        .frame(maxWidth: 320).accessibilityLabel(title)
    } label: { Text(title).appFont(size: 14, weight: .medium) }
  }
}

struct SettingsSecureField: View {
  let title: String
  @Binding var text: String
  var prompt: Text? = nil

  init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
    self.title = title; _text = text; self.prompt = prompt
  }

  var body: some View {
    LabeledContent {
      SecureField(title, text: $text, prompt: prompt)
        .textFieldStyle(.roundedBorder).labelsHidden()
        .frame(maxWidth: 320).accessibilityLabel(title)
    } label: { Text(title).appFont(size: 14, weight: .medium) }
  }
}
