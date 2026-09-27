import SwiftUI

struct SkillsView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var creating = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("技能").appFont(.title2, weight: .semibold)
        Text("\(store.installedPluginSkills.count)")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("新建技能") { creating = true }
          .disabled(!store.pluginsLoaded)
        Button("导入技能…") { store.chooseStandaloneSkillFolder() }
          .disabled(!store.pluginsLoaded)
        Button("重新加载") { Task { await store.loadPlugins() } }
          .disabled(store.pluginsLoading)
        Button("返回任务") { store.returnToWorkspace() }
          .keyboardShortcut(.cancelAction)
      }

      TextField("搜索技能", text: $query)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索技能")

      if !store.pluginsEnabled {
        Label("插件与技能已在设置中关闭", systemImage: "info.circle")
          .foregroundStyle(.secondary)
      }

      ScrollView {
        Text("已安装").appFont(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.bottom, 8)
        PluginSkillsView(store: store, query: query, layout: .cards)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let error = store.pluginsError {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button("重试") { Task { await store.loadPlugins() } }
            .disabled(store.pluginsLoading)
        }.padding(12)
          .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { if !store.pluginsLoaded { await store.loadPlugins() } }
    .sheet(isPresented: $creating) {
      SkillCreationView(store: store) { query = "" }
    }
  }
}

private struct SkillCreationView: View {
  let store: WorkspaceStore
  let created: () -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name = ""
  @State private var purpose = ""
  @State private var instructions = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建技能").appFont(.title2, weight: .semibold)
      Text("技能保存在 ShipiOS 的独立目录，并可在任务中通过 $名称 调用。")
        .foregroundStyle(.secondary)
      Form {
        TextField("名称", text: $name, prompt: Text("例如 code-review"))
          .focused($nameFocused)
        TextField("用途描述", text: $purpose, prompt: Text("说明何时使用这个技能"))
        VStack(alignment: .leading, spacing: 8) {
          Text("技能指令")
          TextEditor(text: $instructions)
            .font(.body)
            .frame(minHeight: 190)
            .border(.secondary.opacity(0.3))
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("创建") {
          if store.createStandaloneSkill(id: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: purpose, instructions: instructions) {
            created()
            dismiss()
          } else { error = store.pluginsError ?? "无法创建技能。" }
        }.buttonStyle(.borderedProminent)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(minWidth: 560, idealWidth: 640, minHeight: 400)
    .onAppear { nameFocused = true }
  }
}
