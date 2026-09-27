import SwiftUI

struct SkillsView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("技能").appFont(.title2, weight: .semibold)
        Text("\(store.installedPluginSkills.count)")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
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
        PluginSkillsView(store: store, query: query)
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
  }
}
