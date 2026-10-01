import SwiftUI

struct AppshotSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("截取应用快照，向 ChatGPT 展示你最前端的窗口")
            .appFont(size: 18, weight: .semibold)
          Text("应用快照包含窗口截图；获得辅助功能权限后，还可附带窗口中的文字。")
            .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Section("快捷键") {
        SettingsSegmentedPicker(title: "快捷键", description: "同时按下两个 ⌘ 键截取应用快照。",
          selection: Binding(
            get: { store.appshotHotkeyEnabled },
            set: { store.appshotHotkeyEnabled = $0 }),
          options: [
            .init(value: true, title: "两个 ⌘ 键"),
            .init(value: false, title: "无")
          ])
          .settingsSearchTarget(.appshotHotkey)
        if store.appshotHotkeyEnabled && !store.accessibilityGranted {
          HStack {
            Text("在其他应用中使用快捷键需要辅助功能权限。")
              .foregroundStyle(.secondary)
            Spacer()
            Button("打开系统设置") { store.openAccessibilitySettings() }
          }
        }
      }
      Section("发送") {
        SettingsSegmentedPicker(title: "Appshot 发送目标",
          description: store.appshotDestination.explanation,
          selection: Binding(
            get: { store.appshotDestination },
            set: { store.appshotDestination = $0 }),
          options: AppshotDestination.allCases.map {
            SettingsSegmentOption(value: $0, title: $0.title)
          })
          .settingsSearchTarget(.appshotDestination)
        SettingsToggle(title: "播放音效", description: "截取成功时播放系统提示音。",
          isOn: Binding(
            get: { store.appshotSoundEnabled },
            set: { store.appshotSoundEnabled = $0 }))
          .settingsSearchTarget(.appshotSound)
      }
    }.settingsFormStyle().appSurface()
      .onAppear { store.refreshComputerUsePermissions() }
  }
}
