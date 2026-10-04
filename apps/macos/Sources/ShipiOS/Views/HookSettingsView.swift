import SwiftUI

struct HookSettingsView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focusedSource: String?
  @State private var returnSourceID: String?

  var body: some View {
    SettingsScrollPage(title: "Hooks", subtitle: "管理配置和插件中的生命周期 Hooks。") {
      HStack(spacing: 10) {
        Link("了解更多", destination: URL(string: "https://learn.chatgpt.com/docs/hooks")!)
        Button { Task { await store.hookSettings.reload(executable: store.executable) } } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).disabled(store.hookSettings.loading || store.hookSettings.busy)
          .accessibilityLabel("重新加载 Hooks")
          .settingsSearchTarget(.hooksImport)
      }
    } controls: {} content: {
      if store.hookSettings.loading {
        ProgressView("正在读取 Hooks…").frame(maxWidth: .infinity)
      }
      if let error = store.hookSettings.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
      if store.hookSettings.loaded, store.hookSettings.sources.isEmpty {
        ContentUnavailableView("未找到 Hooks", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
          description: Text("配置的 Hooks 将显示在这里。"))
      } else if !store.hookSettings.sources.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("来自插件").appFont(.headline).accessibilityAddTraits(.isHeader)
          ForEach(store.hookSettings.groups) { source in
            Button {
              guard !store.hasSettingsConfirmation, store.destination == .settings else { return }
              returnSourceID = source.id; focusedSource = nil; store.hookSettings.open(source.id)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "shippingbox").frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                  Text(source.name).appFont(.subheadline).foregroundStyle(.primary)
                  Text(source.label).appFont(.caption).foregroundStyle(.secondary)
                  if !source.pluginEnabled { Text("插件已停用").appFont(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if !source.warnings.isEmpty {
                  Label("配置问题", systemImage: "exclamationmark.triangle").appFont(.caption)
                }
                if source.reviewCount > 0 { Text("\(source.reviewCount) 项待审阅").appFont(.caption) }
                Text("\(source.activeCount)/\(source.hooks.count) 已启用").appFont(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").appFont(.caption).foregroundStyle(.secondary)
              }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.resolvedColors["surface"].color, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 0.5))
            }.buttonStyle(.plain).disabled(store.hookSettings.loading)
              .settingsActionFocus($focusedSource, equals: source.id)
              .accessibilityIdentifier("hook-source-" + source.id)
          }
        }.settingsSearchTarget(.hooksInstalled)
      }
    }
    .task(id: store.hookSettings.revision) { await store.hookSettings.reload(executable: store.executable) }
    .onSettingsConfirmationDismissal(store.hookSettings.selectedSourceID != nil,
      store: store, page: .hooks) { focusedSource = returnSourceID }
  }
}
