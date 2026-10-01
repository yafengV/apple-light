import SwiftUI

/// The choice belongs to the draft or task, not to whichever task happens to
/// be selected in another window when the menu action runs.
struct ComposerPermissionsMenu: View {
  @Bindable var store: WorkspaceStore
  let taskID: String?
  let draftKey: String

  private var effective: AgentRuntimePreferences {
    store.composerRuntimePreferences(taskID: taskID, draftKey: draftKey)
  }

  private var hasOverride: Bool {
    if let taskID { return store.library.taskRuntimePreferences[taskID] != nil }
    return store.library.newTaskRuntimePreferences[draftKey] != nil
  }

  private var title: String {
    if effective.sandboxMode == .fullAccess { return "完全访问" }
    if effective.sandboxMode == .readOnly { return "只读" }
    return "默认权限"
  }

  var body: some View {
    Menu {
      Button {
        _ = store.saveComposerRuntimePreferences(nil, taskID: taskID, draftKey: draftKey)
      } label: {
        if !hasOverride { Label("沿用全局设置", systemImage: "checkmark") }
        else { Text("沿用全局设置") }
      }
      Divider()
      Menu("审批策略") {
        ForEach(AgentApprovalPolicy.allCases, id: \.self) { policy in
          Button {
            var choice = effective
            choice.approvalPolicy = policy
            _ = store.saveComposerRuntimePreferences(choice, taskID: taskID, draftKey: draftKey)
          } label: {
            if effective.approvalPolicy == policy {
              Label(policy.title, systemImage: "checkmark")
            } else { Text(policy.title) }
          }
        }
      }
      Menu("文件访问") {
        ForEach(AgentSandboxMode.visibleOptions(
          showFullAccess: store.library.showFullAccessInComposer
            || effective.sandboxMode == .fullAccess), id: \.self) { mode in
          Button {
            var choice = effective
            choice.sandboxMode = mode
            if mode != .workspaceWrite { choice.networkAccess = false }
            _ = store.saveComposerRuntimePreferences(choice, taskID: taskID, draftKey: draftKey)
          } label: {
            if effective.sandboxMode == mode {
              Label(mode.title, systemImage: "checkmark")
            } else { Text(mode.title) }
          }
        }
      }
      if effective.sandboxMode == .workspaceWrite {
        Button {
          var choice = effective
          choice.networkAccess.toggle()
          _ = store.saveComposerRuntimePreferences(choice, taskID: taskID, draftKey: draftKey)
        } label: {
          if effective.networkAccess {
            Label("允许网络访问", systemImage: "checkmark")
          } else { Text("允许网络访问") }
        }
      }
    } label: {
      Label(title, systemImage: "lock.shield")
        .appFont(.caption)
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityLabel("权限：\(title)")
    .help(taskID == nil ? "为新任务选择 Codex Core 权限" : "为当前任务下一轮选择 Codex Core 权限")
    .disabled(!store.libraryLoaded)
  }
}
