import SwiftUI

struct FileSelectionEditPanel: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let taskID: String?
  @FocusState private var instructionFocused: Bool

  private var session: FileSelectionEditSession { workspace.selectionEdit }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("编辑选区").appFont(.caption, weight: .semibold)
        Spacer()
        Button("关闭") { session.close(); workspace.fileFocusRequest = UUID() }
      }
      TextField("描述要怎样修改选中的代码", text: Binding(
        get: { session.instruction }, set: { session.instruction = $0 }))
        .textFieldStyle(.roundedBorder).focused($instructionFocused)
        .onSubmit { generate() }
        .disabled(session.generating)
      HStack {
        Button(session.generating ? "取消生成" : "生成修改") {
          if session.generating { session.cancel() } else { generate() }
        }.disabled(!session.generating && (session.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !session.canGenerate(path: workspace.selectedFile, source: workspace.fileText)))
        if session.generating { ProgressView().controlSize(.small) }
        Spacer()
      }
      if let error = session.error {
        Text(error).foregroundStyle(.orange).textSelection(.enabled).appFont(.caption)
      }
      if !session.canGenerate(path: workspace.selectedFile, source: workspace.fileText) {
        Text("文件或选区已变化，请重新选择后打开。")
          .foregroundStyle(.orange).appFont(.caption)
      }
      if let request = session.request, let proposal = session.proposal {
        HStack(alignment: .top, spacing: 8) {
          preview("原选区", request.selectedText ?? "")
          preview("建议替换", proposal.replacement)
        }.frame(height: 160)
        HStack {
          Button("拒绝") { session.close(); workspace.fileFocusRequest = UUID() }
          Button("编辑要求") { session.revise(); instructionFocused = true }
          Spacer()
          if !session.canApply(path: workspace.selectedFile, source: workspace.fileText) {
            Text("文件或选区已变化，请重新生成").foregroundStyle(.orange).appFont(.caption)
          }
          Button("接受修改") {
            if session.accept(path: workspace.selectedFile, source: workspace.fileText) {
              workspace.fileFocusRequest = UUID()
            }
          }.buttonStyle(.borderedProminent)
            .disabled(!session.canApply(path: workspace.selectedFile, source: workspace.fileText))
        }
      }
    }.appFont(.caption).padding(10).background(Color.secondary.opacity(0.06))
      .task { instructionFocused = true }
  }

  private func preview(_ title: String, _ content: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      ScrollView {
        Text(content.isEmpty ? "（删除选区）" : content)
          .appFont(.caption, design: .monospaced).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.padding(6).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }.frame(maxWidth: .infinity)
  }

  private func generate() {
    guard session.canGenerate(path: workspace.selectedFile, source: workspace.fileText) else { return }
    let workspace = workspace
    let store = store
    let taskID = taskID
    session.generate { request in
      try await store.generateFileSelectionEdit(request, taskID: taskID, workspace: workspace)
    }
  }
}
