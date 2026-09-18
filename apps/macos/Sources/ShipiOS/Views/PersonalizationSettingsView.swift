import SwiftUI

struct PersonalizationSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      Section("回复风格") {
        Picker(
          "默认风格",
          selection: Binding(
            get: { store.personalization.personality },
            set: { _ = store.savePersonality($0) })
        ) {
          ForEach(ResponsePersonality.allCases) { personality in
            Text(personality.title).tag(personality)
          }
        }.pickerStyle(.segmented).disabled(!store.personalizationLoaded).settingsSearchTarget(.replyStyle)
        Text("选择“无”会关闭额外的风格指令。更改用于下一次模型请求。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section("新任务建议") {
        SettingsToggle(
          title: "显示建议提示",
          description: "在空白新任务中显示可直接填入输入区的起步建议。关闭后不会影响已有任务或草稿。",
          isOn: Binding(
            get: { store.personalization.showSuggestedPrompts },
            set: { _ = store.saveSuggestedPrompts($0) })
        ).disabled(!store.personalizationLoaded).settingsSearchTarget(.suggestions)
      }
      Section {
        HStack(alignment: .center, spacing: 16) {
          SettingsControlLabel(title: "自定义指令",
            description: "为后续模型会话提供额外指令和背景。这些内容会发送给你配置的 API 服务。")
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("保存") { store.savePersonalizationEdits() }
            .accessibilityLabel("保存自定义指令")
            .help("保存自定义指令（⌘S）")
            .disabled(!store.canSavePersonalizationEdits)
        }
        SettingsTextEditor(text: $store.personalizationDraft, label: "自定义指令",
          placeholder: "添加自定义指令…")
          .appFont(size: 13).frame(minHeight: 190)
          .accessibilityLabel("自定义指令").settingsSearchTarget(.instructions)
          .disabled(!store.personalizationLoaded)
      }
      if let error = store.personalizationError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadPersonalization() } }
            .disabled(store.personalizationLoading)
        }
      }
    }.settingsFormStyle().appSurface()
  }
}
