import SwiftUI

struct PluginDetailView: View {
  @Bindable var store: WorkspaceStore
  @State private var confirmingRemoval = false
  @State private var removalID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Button { store.closePluginDetail() } label: {
          Label("返回", systemImage: "arrow.left")
        }.keyboardShortcut(.cancelAction).accessibilityLabel("返回插件来源页面")
        Spacer()
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let current = store.currentPluginDetail {
            detail(current)
          } else if store.pluginsLoading {
            ProgressView("正在读取插件…")
          } else {
            ContentUnavailableView("插件未安装", systemImage: "shippingbox",
              description: Text("插件可能已被卸载。返回目录可查看当前安装的插件。"))
          }
          if let error = store.pluginsError {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
            Button("重新加载") { Task { await store.loadPlugins() } }
              .disabled(store.pluginsLoading)
          }
        }.frame(maxWidth: 820, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).appSurface()
      .alert("卸载插件？", isPresented: $confirmingRemoval) {
        Button("取消", role: .cancel) { removalID = nil }
        Button("卸载插件", role: .destructive) {
          if let id = removalID { _ = store.removePlugin(id) }
          removalID = nil
        }
      } message: {
        Text("将从 ShipiOS 移除这个插件。外部服务连接不会被修改。")
      }
  }

  @ViewBuilder private func detail(_ current: PluginInstallation) -> some View {
    HStack {
      Image(systemName: "shippingbox.fill").font(.largeTitle)
      VStack(alignment: .leading) {
        Text(current.name).appFont(.title2, weight: .semibold)
        Text("\(current.id) · \(current.version)").foregroundStyle(.secondary).textSelection(.enabled)
      }
      Spacer()
      Toggle("启用", isOn: Binding(
        get: { store.currentPluginDetail?.enabled ?? false },
        set: { _ = store.setPluginEnabled($0, id: current.id) }))
        .disabled(!store.pluginsLoaded)
      Menu {
        Button("在 Finder 中显示") { store.revealPlugin(current.id) }
        Button("卸载插件", role: .destructive) {
          removalID = current.id
          confirmingRemoval = true
        }.disabled(!store.pluginsLoaded)
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("插件操作：\(current.name)")
    }
    if !current.summary.isEmpty { Text(current.summary).textSelection(.enabled) }
    GroupBox("包含的组件") {
      VStack(alignment: .leading, spacing: 8) {
        component("技能", value: current.components.skills)
        component("MCP 服务", value: current.components.mcpServers)
        component("浏览器扩展", value: current.components.hasBrowserExtension ? 1 : 0)
        component("钩子", value: current.components.hasHooks ? 1 : 0)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
    Text("输入区可用 @标识 显式加载插件技能；MCP 服务、浏览器扩展和钩子的运行能力尚未接入。")
      .appFont(.caption).foregroundStyle(.secondary)
    if current.components.skills > 0 {
      GroupBox("技能") {
        PluginSkillsView(store: store, pluginID: current.id).padding(8)
      }
    }
  }

  private func component(_ title: String, value: Int) -> some View {
    HStack {
      Image(systemName: value > 0 ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(value > 0 ? Color.green : .secondary)
      Text(title)
      Spacer()
      Text(value > 0 ? "\(value)" : "无").foregroundStyle(.secondary)
    }
  }
}
