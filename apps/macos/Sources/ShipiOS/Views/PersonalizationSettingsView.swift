import SwiftUI

struct PersonalizationSettingsView: View {
  @Bindable var store: WorkspaceStore
  @FocusState private var navigationFocus: String?

  var body: some View {
    SettingsForm {
      SettingsSection("ShipiOS 记忆") {
        SettingsToggle(title: "启用记忆",
          description: "将本机保存的记忆用于后续模型会话。关闭不会删除内容。",
          isOn: Binding(get: { store.memoryPreferences.enabled },
            set: { _ = store.saveMemoryEnabled($0) }))
          .disabled(!store.memoriesLoaded)
        navigationRow("管理记忆", description: "查看、编辑和删除本机保存的记忆。") {
          store.requestSettingsPage(.memories, onCancelFocus: { navigationFocus = "管理记忆" })
        }
      }
      SettingsSection("权限") {
        navigationRow("自定义规则", description: "管理任务可使用的命名权限档案。") {
          store.revealSetting(.init(page: .general, field: .generalNamedPermissions), onCancelFocus: {
            if store.settingsPage == .personalization { navigationFocus = "自定义规则" }
            else { store.settingsSearchFocusRequest = UUID() }
          })
        }
      }
      SettingsSection("回复风格") {
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
      SettingsSection("新任务建议") {
        SettingsToggle(
          title: "显示建议提示",
          description: "在空白新任务中显示可直接填入输入区的起步建议。关闭后不会影响已有任务或草稿。",
          isOn: Binding(
            get: { store.personalization.showSuggestedPrompts },
            set: { _ = store.saveSuggestedPrompts($0) })
        ).disabled(!store.personalizationLoaded).settingsSearchTarget(.suggestions)
      }
      SettingsSection {
        HStack(alignment: .center, spacing: 16) {
          SettingsControlLabel(title: "自定义指令",
            description: "为后续模型会话提供额外指令和背景。这些内容会发送给你配置的 API 服务。")
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("保存") { store.savePersonalizationEdits() }
            .accessibilityLabel("保存自定义指令")
            .help("保存自定义指令（⌘S）")
            .disabled(!store.canSavePersonalizationEdits)
        }
        VStack(alignment: .leading, spacing: 12) { instructionsContent }
          .frame(maxWidth: .infinity, alignment: .leading)
          .settingsSearchTarget(.instructions)
      }
    }.settingsFormStyle().appSurface()
  }

  private func navigationRow(_ title: String, description: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 16) {
        SettingsControlLabel(title: title, description: description)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }.contentShape(Rectangle())
    }.buttonStyle(.plain)
      .settingsActionFocus($navigationFocus, equals: title, activate: action)
  }

  @ViewBuilder private var instructionsContent: some View {
    if store.personalizationLoaded {
      SettingsTextEditor(text: $store.personalizationDraft, label: "自定义指令",
        placeholder: "添加自定义指令…")
        .appFont(size: 13).frame(minHeight: 190)
        .accessibilityLabel("自定义指令")
      if let error = store.personalizationError {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
    } else if store.personalizationLoading || store.personalizationError == nil {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small).accessibilityHidden(true)
        Text("正在加载自定义指令…").foregroundStyle(.secondary)
      }.accessibilityElement(children: .combine)
    } else {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("无法加载个性化设置和自定义指令。")
          if let error = store.personalizationError {
            Text(error).appFont(.caption).textSelection(.enabled)
          }
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        Button("重试") { Task { await store.loadPersonalization() } }
          .accessibilityLabel("重新加载自定义指令")
      }
    }
  }
}
