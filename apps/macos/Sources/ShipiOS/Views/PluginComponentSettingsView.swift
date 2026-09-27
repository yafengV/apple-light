import SwiftUI

struct PluginComponentSettingsView: View {
  enum Kind {
    case mcpServers, hooks, plugins, skills

    var emptyTitle: String {
      switch self {
      case .mcpServers: "尚未安装 MCP 服务器"
      case .hooks: "尚未安装 Hooks"
      case .plugins: "尚未安装插件"
      case .skills: "尚未安装技能"
      }
    }

    var explanation: String {
      switch self {
      case .mcpServers:
        "MCP 服务器随 ShipiOS 插件保存在独立数据目录中。当前页面可以检查声明并统一启停插件。"
      case .hooks:
        "这里可检查已安装插件的 Hook 声明。启用插件不会授权或执行 Hook；运行时接入前，所有 Hook 均保持停用。"
      case .plugins:
        "插件可以包含技能、MCP 服务器、Hooks 和浏览器扩展。ShipiOS 不读取个人 Codex 的插件目录。"
      case .skills:
        "已启用的技能可以在输入区用 $名称 显式加入模型上下文。"
      }
    }
  }

  @Bindable var store: WorkspaceStore
  let kind: Kind
  var query = ""
  var showsIntroduction = true

  private var plugins: [PluginInstallation] {
    store.pluginPreferences.installed.filter { plugin in
      guard matches([plugin.name, plugin.summary, plugin.id]) else { return false }
      switch kind {
      case .mcpServers: return plugin.components.mcpServers > 0
      case .hooks: return plugin.components.hasHooks
      case .plugins: return true
      case .skills: return plugin.components.skills > 0
      }
    }
  }

  private func matches(_ values: [String]) -> Bool {
    let document = values.joined(separator: " ")
    return query.split(whereSeparator: \.isWhitespace).allSatisfy {
      document.localizedStandardContains(String($0))
    }
  }

  var body: some View {
    Form {
      if showsIntroduction {
        Section {
          Text(kind.explanation).foregroundStyle(.secondary)
          HStack {
            Button("导入本地插件…") { store.choosePluginFolder() }
              .disabled(!store.pluginsLoaded)
              .settingsSearchTarget(importSearchField)
            Button("重新加载") { Task { await store.loadPlugins() } }
              .disabled(store.pluginsLoading)
          }
        }
      }

      Section("已安装") {
        if store.pluginsLoading {
          ProgressView("正在读取插件…")
        } else if plugins.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? kind.emptyTitle : "没有匹配的扩展",
            systemImage: SettingsPage(rawValue: pageID)?.icon ?? "shippingbox",
            description: Text(query.isEmpty ? "使用“导入本地插件”添加插件包。" : "尝试其他搜索词。"))
            .frame(maxWidth: .infinity)
        } else {
          ForEach(plugins) { plugin in
            VStack(alignment: .leading, spacing: 8) {
              HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").foregroundStyle(store.appearance.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                  Button { store.openPluginDetail(plugin.id) } label: {
                    Text(plugin.name).appFont(.headline)
                  }.buttonStyle(.plain).accessibilityLabel("查看插件详情：\(plugin.name)")
                  Text(componentDescription(plugin)).appFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                  "启用",
                  isOn: Binding(
                    get: { plugin.enabled },
                    set: { _ = store.setPluginEnabled($0, id: plugin.id) })
                ).labelsHidden().accessibilityLabel("启用插件：\(plugin.name)")
              }
              if kind == .hooks { hookDetails(for: plugin) }
            }.padding(.vertical, 4)
          }
        }
      }

      .settingsSearchTarget(installedSearchField)
      if kind == .skills, !store.pluginSkills.isEmpty {
        Section("可调用技能") {
          ForEach(store.pluginSkills.filter { matches([$0.title, $0.mention, $0.pluginName]) }) { skill in
            LabeledContent("$" + skill.mention) {
              Text(skill.pluginName).foregroundStyle(.secondary)
            }
          }
        }
      }

      if let error = store.pluginsError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadPlugins() } }
            .disabled(store.pluginsLoading)
        }
      }
    }.settingsFormStyle().appSurface()
  }

  private var pageID: String {
    switch kind {
    case .mcpServers: SettingsPage.mcpServers.rawValue
    case .hooks: SettingsPage.hooks.rawValue
    case .plugins: SettingsPage.plugins.rawValue
    case .skills: SettingsPage.skills.rawValue
    }
  }

  private var importSearchField: SettingsSearchField {
    switch kind {
    case .mcpServers: .mcpImport
    case .hooks: .hooksImport
    case .plugins: .pluginsImport
    case .skills: .skillsImport
    }
  }

  private var installedSearchField: SettingsSearchField {
    switch kind {
    case .mcpServers: .mcpInstalled
    case .hooks: .hooksInstalled
    case .plugins: .pluginsInstalled
    case .skills: .skillsInstalled
    }
  }

  private func componentDescription(_ plugin: PluginInstallation) -> String {
    switch kind {
    case .mcpServers: "\(plugin.components.mcpServers) 个 MCP 服务器 · \(plugin.id)"
    case .hooks: "包含 Hooks · \(plugin.id)"
    case .plugins:
      plugin.components.labels.isEmpty
        ? plugin.id : plugin.components.labels.joined(separator: " · ")
    case .skills: "\(plugin.components.skills) 个技能 · \(plugin.id)"
    }
  }

  @ViewBuilder private func hookDetails(for plugin: PluginInstallation) -> some View {
    let result = Result { try PluginHookCatalog.declarations(pluginID: plugin.id, root: store.dataRoot) }
    switch result {
    case .success(let declarations):
      if declarations.isEmpty {
        Text("未找到可显示的命令 Hook 声明 · 不会执行")
          .appFont(.caption).foregroundStyle(.secondary)
      } else {
        DisclosureGroup("\(declarations.count) 条 Hook 声明 · 未授权执行") {
          ForEach(Array(declarations.enumerated()), id: \.offset) { _, declaration in
            VStack(alignment: .leading, spacing: 3) {
              Text(declaration.event).appFont(.subheadline)
              Text(declaration.command).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
              Text(declaration.source).appFont(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
          }
        }
      }
    case .failure(let error):
      Text("无法读取 Hook 声明：\(error.localizedDescription)")
        .appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
    }
  }
}
