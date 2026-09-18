import SwiftUI

struct PluginsView: View {
  enum Section: String, CaseIterable, Identifiable {
    case discover, installed
    var id: String { rawValue }
    var title: String { self == .discover ? "发现" : "已安装" }
  }

  @Bindable var store: WorkspaceStore
  @State private var section: Section = .discover
  @State private var query = ""
  @State private var removing: PluginInstallation?

  private var installed: [PluginInstallation] {
    store.pluginPreferences.installed.filter {
      query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        || $0.summary.localizedCaseInsensitiveContains(query)
        || $0.id.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Text("插件").appFont(.title2, weight: .semibold)
        Picker("目录", selection: $section) {
          ForEach(Section.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).frame(width: 210)
        Spacer()
        Button("导入本地插件…") { store.choosePluginFolder() }
          .disabled(!store.pluginsLoaded)
        Button("返回任务") { store.returnToWorkspace() }.keyboardShortcut(.cancelAction)
      }
      TextField("搜索插件", text: $query).textFieldStyle(.roundedBorder)
      if store.pluginsLoading {
        ProgressView("正在读取插件…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if section == .discover {
        discover
      } else {
        installedList
      }
      if let error = store.pluginsError {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          Button("重新加载") { Task { await store.loadPlugins() } }
        }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
      .alert("卸载插件？", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } })
      ) {
        Button("取消", role: .cancel) { removing = nil }
        Button("卸载插件", role: .destructive) {
          if let plugin = removing { _ = store.removePlugin(plugin.id) }
          removing = nil
        }
      } message: {
        Text("将从 ShipiOS 的独立插件目录移除 \(removing?.name ?? "这个插件")。外部服务连接不会被修改。")
      }
  }

  private var discover: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 10) {
          Label("统一插件目录", systemImage: "shippingbox")
            .appFont(.headline)
          Text("Codex 的公开目录可提供技能、MCP 服务、浏览器扩展和钩子。ShipiOS 当前保持独立运行时，因此不会读取或修改用户安装的 Codex 插件。")
            .foregroundStyle(.secondary)
          Text("公开目录与账户连接尚未接入。你可以先导入本地插件包，检查其组成、启用状态和独立存储。")
            .foregroundStyle(.secondary)
          Button("选择本地插件文件夹…") { store.choosePluginFolder() }
            .disabled(!store.pluginsLoaded)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
          .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

        if !store.pluginPreferences.installed.isEmpty {
          Text("最近安装").appFont(.headline)
          ForEach(installed.prefix(4)) { plugin in pluginRow(plugin) }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var installedList: some View {
    Group {
      if installed.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "尚未安装插件" : "没有匹配的插件",
          systemImage: "shippingbox",
          description: Text(query.isEmpty ? "导入本地插件后会显示在这里。" : "尝试其他搜索词。"))
      } else {
        List(installed) { plugin in pluginRow(plugin).padding(.vertical, 5) }
      }
    }
  }

  private func pluginRow(_ plugin: PluginInstallation) -> some View {
    HStack(spacing: 14) {
      Image(systemName: "shippingbox.fill").font(.title2).frame(width: 34)
        .foregroundStyle(store.appearance.accentColor)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(plugin.name).appFont(.headline)
          Text(plugin.version).appFont(.caption).foregroundStyle(.secondary)
        }
        if !plugin.summary.isEmpty {
          Text(plugin.summary).appFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Text(plugin.components.labels.isEmpty ? "未声明组件" : plugin.components.labels.joined(separator: " · "))
          .appFont(.caption2).foregroundStyle(.tertiary)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Toggle("启用", isOn: Binding(
        get: { plugin.enabled },
        set: { _ = store.setPluginEnabled($0, id: plugin.id) }))
        .labelsHidden().help(plugin.enabled ? "停用插件" : "启用插件")
      Button("详情") { store.openPluginDetail(plugin.id) }
        .accessibilityLabel("查看插件详情：\(plugin.name)")
      Menu {
        Button("在 Finder 中显示") { store.revealPlugin(plugin.id) }
        Button("卸载插件", role: .destructive) { removing = plugin }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("插件菜单：\(plugin.name)")
    }.contentShape(Rectangle())
  }
}
