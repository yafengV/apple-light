import SwiftUI

/// Availability and the default choice are separate: enabling a mode does not
/// change an existing task or silently grant it broader access.
struct GeneralPermissionSettingsSection: View {
  @Bindable var store: WorkspaceStore
  @State private var confirmingFullAccess = false
  @State private var status = ""

  var body: some View {
    Section("权限") {
      SettingsMenuPicker("默认权限",
        description: "新建 Codex Core 任务使用此模式；已有任务保留自己的权限。",
        selection: Binding(
          get: { store.library.agentRuntimePreferences },
          set: { selected in
            status = store.saveAgentRuntimePreferences(selected)
              ? "已保存默认权限。" : (store.error ?? "保存失败，请重试。")
          }), options: defaultOptions)
        .disabled(!store.libraryLoaded)
        .settingsSearchTarget(.generalDefaultPermissions)

      SettingsToggle(title: "自动审查",
        description: "允许在输入区选择自动审查批准；显示选项不会更改现有任务。",
        isOn: Binding(
          get: { store.library.showAutoReviewInComposer },
          set: { visible in
            status = store.saveShowAutoReviewInComposer(visible)
              ? (visible ? "自动审查已加入权限菜单，尚未启用。" : "自动审查已从新任务权限菜单移除。")
              : (store.generalSettingsError ?? "保存失败，请重试。")
          }))
        .disabled(!store.libraryLoaded)
        .settingsSearchTarget(.generalAutoReview)

      SettingsToggle(title: "完全访问",
        description: "允许在输入区选择不受文件沙箱限制的模式；显示选项不会更改现有任务。",
        isOn: Binding(
          get: { store.library.showFullAccessInComposer },
          set: { visible in
            if visible { confirmingFullAccess = true }
            else {
              status = store.saveShowFullAccessInComposer(false)
                ? "完全访问已从新任务权限菜单移除。"
                : (store.generalSettingsError ?? "保存失败，请重试。")
            }
          }))
        .disabled(!store.libraryLoaded)
        .settingsSearchTarget(.agentFullAccess)

      Text("开启模式只会让它出现在权限菜单中。关闭模式时，新任务默认权限恢复为按需请求批准；已有任务的权限快照保持不变。")
        .appFont(.caption).foregroundStyle(.secondary)
      if !status.isEmpty { Text(status).appFont(.caption).foregroundStyle(.secondary) }
    }
    .alert("允许显示完全访问？", isPresented: $confirmingFullAccess) {
      Button("取消", role: .cancel) {}
      Button("确认") {
        status = store.saveShowFullAccessInComposer(true)
          ? "完全访问已加入权限菜单，尚未启用。"
          : (store.generalSettingsError ?? "保存失败，请重试。")
      }
    } message: {
      Text("选择完全访问后，Agent 可访问网络、读取和编辑电脑上的文件，且不再请求批准，包括执行可能造成破坏的命令。确认仅将完全访问加入输入区权限菜单，不会自动启用。")
    }
  }

  private var defaultOptions: [SettingsMenuOption<AgentRuntimePreferences>] {
    let current = store.library.agentRuntimePreferences
    var options = [SettingsMenuOption(value: AgentRuntimePreferences.askForApproval, title: "按需请求批准")]
    if store.library.showAutoReviewInComposer || current == .approveForMe {
      options.append(SettingsMenuOption(value: AgentRuntimePreferences.approveForMe, title: "自动审查批准"))
    }
    if store.library.showFullAccessInComposer || current.isFullAccessPreset {
      options.append(SettingsMenuOption(value: AgentRuntimePreferences.fullAccess, title: "完全访问"))
    }
    if !options.contains(where: { $0.value == current }) {
      options.append(SettingsMenuOption(value: current, title: "自定义权限（当前）"))
    }
    return options
  }
}
