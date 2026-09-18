import SwiftUI

struct PluginSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    ZStack {
      mainPage
        .opacity(store.mcpServerEditor == nil ? 1 : 0)
        .allowsHitTesting(store.mcpServerEditor == nil)
        .disabled(store.mcpServerEditor != nil)
        .accessibilityHidden(store.mcpServerEditor != nil)
      if let server = store.mcpServerEditor {
        MCPServerEditorView(store: store, server: server).id(server.id)
      }
    }.task { if !store.mcpServersLoaded { await store.loadMCPServers() } }
  }

  private var mainPage: some View {
    SettingsScrollPage(title: SettingsPage.plugins.title, subtitle: "管理插件、技能和 MCP") {
      HStack {
        Button("浏览目录") { store.showPlugins() }
        Menu("添加") {
          Button("添加 MCP 服务器…") { store.openMCPServerEditor() }
            .disabled(!store.mcpServersLoaded)
          Button("导入本地插件…") { store.choosePluginFolder() }
            .disabled(!store.pluginsLoaded)
          Button("导入技能…") { store.chooseStandaloneSkillFolder() }
            .disabled(!store.pluginsLoaded)
        }
          .settingsSearchTarget(store.activePluginSettingsSection.importField)
      }
    } controls: {} content: {
      HStack(spacing: 16) {
        if store.pluginsLoading {
          ProgressView().controlSize(.small).accessibilityLabel("正在读取扩展分类")
        } else {
          Picker("管理扩展", selection: Binding(
            get: { store.activePluginSettingsSection }, set: { store.pluginSettingsSection = $0 }
          )) {
            ForEach(store.visiblePluginSettingsSections) { section in
              Text("\(section.title) \(section.count(in: store.pluginPreferences.installed, standaloneSkills: store.pluginPreferences.standaloneSkills.count) + (section == .mcpServers ? store.mcpServers.count : 0))").tag(section)
            }
          }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
        }
        Spacer(minLength: 0)
        TextField("搜索已安装的扩展…", text: $store.pluginSettingsQuery)
          .textFieldStyle(.roundedBorder).frame(maxWidth: 230)
          .accessibilityLabel("搜索已安装的扩展")
      }
      if store.activePluginSettingsSection == .skills {
        Form {
          Section("已安装技能") {
            PluginSkillsView(store: store, query: store.pluginSettingsQuery)
          }.settingsSearchTarget(.skillsInstalled)
          if let error = store.pluginsError {
            Text(error).foregroundStyle(.red)
            Button("重新加载") { Task { await store.loadPlugins() } }.disabled(store.pluginsLoading)
          }
        }.settingsFormStyle().appSurface()
      } else if store.activePluginSettingsSection == .mcpServers {
        MCPSettingsView(store: store)
      } else {
        PluginComponentSettingsView(store: store, kind: kind, query: store.pluginSettingsQuery,
          showsIntroduction: false)
      }
    }
  }

  private var kind: PluginComponentSettingsView.Kind {
    switch store.activePluginSettingsSection {
    case .plugins: .plugins
    case .mcpServers: .mcpServers
    case .skills: .skills
    }
  }
}
