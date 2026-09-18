import SwiftUI

struct EditorSettingsSection: View {
  @Bindable var store: WorkspaceStore
  @State private var available: Set<ExternalEditor> = []
  var body: some View {
    Section("文件打开方式") {
      SettingsMenuPicker("默认编辑器",
        description: "审查页文件名和文件面板的“打开”使用此设置。Cmd 点击差异代码行可定位到工作区文件；已删除的行定位到附近的现有行。",
        selection: $store.preferredEditor,
        options: ExternalEditor.allCases.map { editor in
          SettingsMenuOption(value: editor,
            title: editor.title + (available.contains(editor) ? "" : "（未检测到）"))
        })
      .settingsSearchTarget(.editor)
      HStack {
        Text("行定位支持 Xcode 和 Visual Studio Code。")
        Spacer()
        Button("重新检测") { refresh() }
      }.appFont(.caption).foregroundStyle(.secondary)
    }.onAppear { refresh() }
  }
  private func refresh() {
    available = Set(ExternalEditor.allCases.filter { ExternalEditorService.available($0) })
  }
}
