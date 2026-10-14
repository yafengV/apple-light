import SwiftUI

/// Common workspace preferences stay together; the controls retain their
/// existing bindings and search targets when their presentation is regrouped.
struct GeneralWorkspaceSettingsSection: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    SettingsSection("常规") {
      SettingsLabeledRow {
        SettingsControlLabel(title: "无项目任务文件夹",
          description: "没有项目的任务默认在此位置保存数据。")
      } control: {
        HStack(spacing: 8) {
          Text(store.projectlessWorkspaceRoot.path)
            .appFont(size: 11, design: .monospaced).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            .frame(minWidth: 0, idealWidth: 192, maxWidth: 192, alignment: .leading)
            .help(store.projectlessWorkspaceRoot.path)
          HStack(spacing: 4) {
            Button("更改…") { store.chooseProjectlessWorkspaceRoot() }
            if store.library.projectlessWorkspaceRoot != nil {
              Button("恢复默认") { store.setProjectlessWorkspaceRoot(nil) }
                .buttonStyle(SettingsActionButtonStyle(color: .ghost))
            }
          }.fixedSize()
        }
      }.settingsSearchTarget(.projectlessFolder)
      EditorSettingsSection(store: store, embedded: true)
      SettingsToggle(title: "在菜单栏中显示", description: "主窗口关闭后，让 ShipiOS 保留在 macOS 菜单栏中。",
        isOn: $store.showInMenuBar)
        .accessibilityLabel("在菜单栏中显示 ShipiOS")
        .settingsSearchTarget(.menuBar)
      SettingsToggle(title: "底部面板",
        description: "在应用标题栏显示底部面板布局控制；终端快捷键仍可直接打开底部终端。",
        isOn: $store.showBottomPanelControl)
        .settingsSearchTarget(.bottomPanel)
      SettingsSegmentedPicker(title: "默认终端位置",
        description: "工具栏终端按钮、命令菜单和固定终端恢复都会使用此位置。", selection: Binding(
        get: { store.library.defaultTerminalLocation },
        set: { store.setDefaultTerminalLocation($0) }), options: [
          SettingsSegmentOption(value: .bottom, title: "底部"),
          SettingsSegmentOption(value: .right, title: "右侧")
        ])
        .settingsSearchTarget(.terminalLocation)
      SettingsToggle(title: "运行时防止休眠",
        description: "任务执行期间阻止空闲休眠，结束后自动恢复。显示器仍可熄灭，手动休眠和合盖仍由系统处理。",
        isOn: $store.preventIdleSleep)
        .settingsSearchTarget(.preventSleep)
      if store.sleepPrevention.active {
        Label("正在防止空闲休眠", systemImage: "moon.zzz").foregroundStyle(.secondary)
      }
      if let error = store.sleepPrevention.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
        Button("重试") { store.updateSleepPrevention(force: true) }
      }
    }
  }
}
