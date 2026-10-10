import SwiftUI

struct FileCloseConfirmationView: View {
  @Bindable var workspace: DeveloperWorkspace
  let didClose: () -> Void

  private var saving: Bool {
    workspace.fileCloseRequest.flatMap {
      workspace.fileEditorSessions[workspace.editorKey(for: $0)]?.saving
    } == true
  }
  private var error: String? {
    workspace.fileCloseRequest.flatMap {
      workspace.fileEditorSessions[workspace.editorKey(for: $0)]?.error
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("保存此文件的更改？").appFont(.headline)
      if let path = workspace.fileCloseRequest {
        Text(URL(fileURLWithPath: path).lastPathComponent).foregroundStyle(.secondary)
      }
      Text("当前内容尚未写入磁盘。")
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("放弃更改并关闭", role: .destructive) {
          if workspace.discardRequestedFileClose() { didClose() }
        }.disabled(saving)
        Spacer()
        Button("继续编辑") { workspace.cancelFileClose() }
          .keyboardShortcut(.cancelAction).disabled(saving)
        Button(saving ? "正在保存…" : "保存并关闭") {
          Task { if await workspace.saveAndCloseRequestedFile() { didClose() } }
        }.keyboardShortcut(.defaultAction).disabled(saving)
      }
    }.padding(24).frame(width: 490)
      .interactiveDismissDisabled(saving)
      .accessibilityIdentifier("file-close-confirmation")
  }
}
