import SwiftUI

/// Shared menu content; actions are routed to the window that presented it.
struct ContentTabLauncher: View {
  let placement: WorkspaceTabPlacement
  let hasProject: Bool
  let canReopen: Bool
  let plugins: [PluginInstallation]
  let dismiss: () -> Void
  let perform: (ContentTabLauncherAction) -> Void

  private var enabledPlugins: [PluginInstallation] { plugins.filter(\.enabled) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if placement == .bottom {
          section("终端") {
            action("打开底部终端", icon: "terminal", .terminal)
            action("终端选项", icon: "slider.horizontal.3", .terminalOptions)
          }
        } else {
          section("推荐") {
            action("浏览器", icon: "globe", .browser)
            if hasProject {
              action("审查", icon: "square.stack.3d.up", .review)
              action("打开底部终端", icon: "terminal", .terminal)
            }
          }
          section("最近工作") {
            if canReopen {
              action("重新打开关闭的标签页", icon: "arrow.uturn.backward", .reopen)
            } else {
              Text("暂无最近关闭的标签页").foregroundStyle(.secondary).appFont(.caption)
                .padding(.horizontal, 8)
            }
          }
          section("插件和 MCP") {
            if enabledPlugins.isEmpty {
              action("浏览插件", icon: "shippingbox", .plugins)
            } else {
              ForEach(enabledPlugins.prefix(4)) { plugin in
                action(plugin.name, icon: "shippingbox", .plugin(plugin.id))
              }
              if enabledPlugins.count > 4 { action("显示全部", icon: "ellipsis", .plugins) }
            }
          }
          section("更多工具") {
            if hasProject { action("文件", icon: "doc.text.magnifyingglass", .files) }
            action("自动化", icon: "clock.arrow.circlepath", .automations)
          }
        }
      }.padding(16)
    }
    .frame(width: 320, height: placement == .bottom ? 150 : 430)
    .accessibilityLabel(placement == .bottom ? "打开底部面板标签" : "新标签页")
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 8)
      content()
    }
  }

  private func action(_ title: String, icon: String, _ action: ContentTabLauncherAction) -> some View {
    Button { dismiss(); perform(action) } label: {
      Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}
