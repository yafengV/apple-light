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
    effective.menuTitle
  }

  var body: some View {
    Menu {
      AgentPermissionOptions(effective: effective, hasOverride: hasOverride,
        showAutoReview: store.library.showAutoReviewInComposer,
        showFullAccess: store.library.showFullAccessInComposer,
        namedProfiles: store.library.namedPermissionProfiles) { choice in
          _ = store.saveComposerRuntimePreferences(choice, taskID: taskID, draftKey: draftKey)
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

/// Keep the presets and advanced controls identical in the main composer,
/// task windows, and the popout home. Presets always select both Codex fields.
struct AgentPermissionOptions: View {
  let effective: AgentRuntimePreferences
  let hasOverride: Bool
  let showAutoReview: Bool
  let showFullAccess: Bool
  let namedProfiles: [AgentNamedPermissionProfile]
  let onSelect: (AgentRuntimePreferences?) -> Void

  private var availableNamedProfiles: [AgentNamedPermissionProfile] {
    namedProfiles.filter {
      !$0.requiresFullAccess || showFullAccess || effective.namedProfile == $0
    }
  }

  var body: some View {
    Button {
      onSelect(nil)
    } label: {
      if !hasOverride { Label("沿用全局设置", systemImage: "checkmark") }
      else { Text("沿用全局设置") }
    }
    Divider()
    Button {
      onSelect(.askForApproval)
    } label: {
      if hasOverride && effective == .askForApproval {
        Label("按需请求批准", systemImage: "checkmark")
      } else { Text("按需请求批准") }
    }
    if showAutoReview || effective.approvalReviewer == .autoReview {
      Button {
        onSelect(.approveForMe)
      } label: {
        if hasOverride && effective == .approveForMe {
          Label("自动审查批准", systemImage: "checkmark")
        } else { Text("自动审查批准") }
      }
    }
    if showFullAccess || effective.sandboxMode == .fullAccess {
      Button {
        onSelect(.fullAccess)
      } label: {
        if hasOverride && effective.isFullAccessPreset {
          Label("完全访问", systemImage: "checkmark")
        } else { Text("完全访问") }
      }
    }
    if !availableNamedProfiles.isEmpty || effective.namedProfile != nil {
      Divider()
      ForEach(availableNamedProfiles) { profile in
        Button {
          onSelect(AgentRuntimePreferences(namedProfile: profile))
        } label: {
          if effective.namedProfile == profile {
            Label(profile.title, systemImage: "checkmark")
          } else { Text(profile.title) }
        }
      }
      if let selected = effective.namedProfile, !namedProfiles.contains(selected) {
        Button {
          onSelect(AgentRuntimePreferences(namedProfile: selected))
        } label: {
          Label("\(selected.title)（当前任务快照）", systemImage: "checkmark")
        }
      }
    }
    Menu("自定义权限") {
      Menu("审批者") {
        ForEach(AgentApprovalReviewer.allCases.filter {
          $0 != .autoReview || showAutoReview || effective.approvalReviewer == .autoReview
        }, id: \.self) { reviewer in
          Button {
            var choice = effective
            choice.namedProfile = nil
            choice.approvalReviewer = reviewer
            onSelect(choice)
          } label: {
            if effective.namedProfile == nil && effective.approvalReviewer == reviewer {
              Label(reviewer.title, systemImage: "checkmark")
            } else { Text(reviewer.title) }
          }
        }
      }
      Menu("审批策略") {
        ForEach(AgentApprovalPolicy.allCases, id: \.self) { policy in
          Button {
            var choice = effective
            choice.namedProfile = nil
            choice.approvalPolicy = policy
            onSelect(choice)
          } label: {
            if effective.namedProfile == nil && effective.approvalPolicy == policy {
              Label(policy.title, systemImage: "checkmark")
            } else { Text(policy.title) }
          }
        }
      }
      Menu("文件访问") {
        ForEach(AgentSandboxMode.visibleOptions(
          showFullAccess: showFullAccess || effective.sandboxMode == .fullAccess), id: \.self) { mode in
          Button {
            var choice = effective
            choice.namedProfile = nil
            choice.sandboxMode = mode
            if mode != .workspaceWrite { choice.networkAccess = false }
            if mode == .fullAccess { choice.approvalPolicy = .never }
            onSelect(choice)
          } label: {
            if effective.namedProfile == nil && effective.sandboxMode == mode {
              Label(mode.title, systemImage: "checkmark")
            } else { Text(mode.title) }
          }
        }
      }
      if effective.namedProfile == nil && effective.sandboxMode == .workspaceWrite {
        Button {
          var choice = effective
          choice.namedProfile = nil
          choice.networkAccess.toggle()
          onSelect(choice)
        } label: {
          if effective.networkAccess {
            Label("允许网络访问", systemImage: "checkmark")
          } else { Text("允许网络访问") }
        }
      }
    }
  }
}
