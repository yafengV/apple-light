import SwiftUI

struct AppearanceThemeImportView: View {
  @Bindable var store: WorkspaceStore
  let dark: Bool
  let onClose: () -> Void
  @State private var value = ""
  @State private var error: String?
  @FocusState private var focused: Bool
  private var valid: Bool { (try? AppearanceThemeShare.decode(value, dark: dark)) != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("导入主题").appFont(.title2, weight: .semibold)
      TextEditor(text: $value).font(.system(size: 12, design: .monospaced))
        .focused($focused).frame(height: 130)
        .accessibilityLabel((dark ? "深色" : "浅色") + "主题分享文本")
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消", action: onClose).keyboardShortcut(.cancelAction)
        Button("导入主题") {
          if store.importThemeShare(value, dark: dark) { onClose() }
          else { error = store.generalSettingsError ?? "导入主题失败。" }
        }.keyboardShortcut(.defaultAction).disabled(!valid || !store.libraryLoaded)
      }
    }.padding(20).frame(width: 500).appSurface().onAppear { focused = true }
  }
}
