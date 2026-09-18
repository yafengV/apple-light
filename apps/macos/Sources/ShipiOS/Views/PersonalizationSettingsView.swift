import SwiftUI

struct PersonalizationSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var saved = false

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
        Toggle(
          "显示建议提示",
          isOn: Binding(
            get: { store.personalization.showSuggestedPrompts },
            set: { _ = store.saveSuggestedPrompts($0) })
        ).disabled(!store.personalizationLoaded).settingsSearchTarget(.suggestions)
        Text("在空白新任务中显示可直接填入输入区的起步建议。关闭后不会影响已有任务或草稿。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section("自定义指令") {
        Text("告诉 ShipiOS 你的偏好，例如回复语言、详细程度或项目约定。")
          .appFont(.callout).foregroundStyle(.secondary)
        SettingsTextEditor(text: $store.personalizationDraft, label: "自定义指令")
          .appFont(size: 13).frame(minHeight: 190)
          .accessibilityLabel("自定义指令").settingsSearchTarget(.instructions)
          .disabled(!store.personalizationLoaded)
        HStack {
          Button("保存指令") { saved = store.saveCustomInstructions() }
            .disabled(!store.personalizationLoaded || store.personalizationDraft == store.customInstructions)
          Button("撤销未保存修改") { store.personalizationDraft = store.customInstructions }
            .disabled(store.personalizationDraft == store.customInstructions)
          Spacer()
          if saved { Label("已保存", systemImage: "checkmark").foregroundStyle(.secondary) }
          else if store.personalizationDraft != store.customInstructions {
            Text("未保存").foregroundStyle(.secondary)
          }
        }
        Text("保存后的指令应用于后续模型会话，并发送给你配置的 API 服务。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      if let error = store.personalizationError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadPersonalization() } }
            .disabled(store.personalizationLoading)
        }
      }
    }.settingsFormStyle().appSurface()
      .onChange(of: store.personalizationDraft) { _, _ in saved = false }
  }
}
