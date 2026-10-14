import SwiftUI

struct EditorSettingsSection: View {
  @Bindable var store: WorkspaceStore
  var embedded = false
  @State private var available: Set<ExternalEditor> = []
  @ViewBuilder var body: some View {
    if embedded { editorRow.onAppear { refresh() } }
    else {
      SettingsSection("文件打开方式") {
        editorRow
        HStack {
          Text("行定位支持 Xcode 和 Visual Studio Code。")
          Spacer()
          Button("重新检测") { refresh() }
        }.appFont(.caption).foregroundStyle(.secondary)
      }.onAppear { refresh() }
    }
  }
  private var editorRow: some View {
    SettingsMenuPicker(embedded ? "默认文件打开位置" : "默认编辑器",
      description: "默认打开文件的位置；行定位支持 Xcode 和 Visual Studio Code。",
      selection: $store.preferredEditor,
      options: ExternalEditor.allCases.map { editor in
        SettingsMenuOption(value: editor,
          title: editor.title + (available.contains(editor) ? "" : "（未检测到）"))
      })
      .settingsSearchTarget(.editor)
      .contextMenu { Button("重新检测编辑器") { refresh() } }
      .help("审查页文件名和文件面板的“打开”使用此设置。Cmd 点击差异代码行可定位到工作区文件。")
  }
  private func refresh() {
    available = Set(ExternalEditor.allCases.filter { ExternalEditorService.available($0) })
  }
}
