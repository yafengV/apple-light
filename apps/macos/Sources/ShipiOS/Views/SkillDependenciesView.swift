import SwiftUI

struct SkillDependenciesView: View {
  @Bindable var store: WorkspaceStore
  let skill: PluginSkillReference
  let dependencies: [SkillToolDependency]
  var projectPath: String? = nil
  let configured: () -> Void
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("所需工具").appFont(.headline)
      if !store.mcpServersLoaded {
        if let message = store.mcpServersError {
          Text(message).foregroundStyle(.red)
          Button("重试") { Task { await store.loadMCPServers() } }
        } else { ProgressView("正在读取连接状态…") }
      }
      ForEach(Array(dependencies.enumerated()), id: \.offset) { _, dependency in
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(dependency.value).appFont(.body, weight: .medium).textSelection(.enabled)
            if let description = dependency.description, !description.isEmpty {
              Text(description).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if store.mcpServersLoaded {
              switch dependency.resolve(in: store.mcpServers) {
              case .configured(let server):
                Text(server.enabled ? (store.mcpConnectionStates[server.id] ?? .disconnected).label : "已停用")
                  .appFont(.caption).foregroundStyle(.secondary)
              case .missing: Text("未安装").appFont(.caption).foregroundStyle(.secondary)
              case .unavailable(let message): Text(message).appFont(.caption).foregroundStyle(.orange)
              }
            }
          }
          Spacer()
          if store.mcpServersLoaded {
            switch dependency.resolve(in: store.mcpServers) {
            case .configured: action("管理", dependency: dependency)
            case .missing: action("配置", dependency: dependency)
            case .unavailable: EmptyView()
            }
          }
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }
    .task { if !store.mcpServersLoaded { await store.loadMCPServers() } }
  }

  private func action(_ title: String, dependency: SkillToolDependency) -> some View {
    Button(title) {
      if store.configureSkillDependency(dependency, skill: skill, projectPath: projectPath) { configured() }
      else { error = store.pluginsError }
    }.accessibilityLabel("\(title)技能所需服务：\(dependency.value)")
  }
}
