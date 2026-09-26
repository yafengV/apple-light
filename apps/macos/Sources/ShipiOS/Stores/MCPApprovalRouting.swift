import SwiftUI

struct MCPApprovalCommands {
  let approve: () -> Void
  let decline: () -> Void
}

private struct MCPApprovalCommandsKey: FocusedValueKey {
  typealias Value = MCPApprovalCommands
}

private struct MCPApprovalSurfaceKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var mcpApprovalSurfaceVisible: Bool {
    get { self[MCPApprovalSurfaceKey.self] }
    set { self[MCPApprovalSurfaceKey.self] = newValue }
  }
}

extension FocusedValues {
  var mcpApprovalCommands: MCPApprovalCommands? {
    get { self[MCPApprovalCommandsKey.self] }
    set { self[MCPApprovalCommandsKey.self] = newValue }
  }
}

struct MCPApprovalKeyContext {
  var visible = true
  var hasSheet = false
  var isRepeat = false
  var editingText = false
  var markedText = false
  var ownsPanelInput = false
}

extension WorkspaceStore {
  var mainMCPApprovalVisible: Bool {
    destination == .workspace && activeWorkspaceContentTab == nil && focusedWorkspaceContentTab == nil
      && renameTaskID == nil && presentedOverlay == nil && !showingModelPicker && !showingBranchPicker && !showingFind
  }

  func activeMCPApproval(taskID: String?) -> UUID? {
    guard let taskID, let task = library.tasks.first(where: { $0.id == taskID }), !task.archived else { return nil }
    for runID in task.runIDs {
      guard let run = library.chatRuns.first(where: { $0.id == runID }), run.isActive else { continue }
      if let record = run.toolExecutions.first(where: {
        $0.status == .awaitingApproval && mcpPendingApprovals[$0.id]?.runID == runID
      }) { return record.id }
    }
    return nil
  }

  func resolveActiveMCPApproval(taskID: String?, decision: MCPApprovalDecision) {
    guard let id = activeMCPApproval(taskID: taskID) else { return }
    resolveMCPApproval(id, decision: decision)
  }

  private func preferredApprovalDecision(_ id: UUID) -> MCPApprovalDecision? {
    guard let context = mcpPendingApprovals[id] else { return nil }
    if context.allowsOnce { return .allowOnce }
    if context.allowsTask { return .allowTask }
    return nil
  }

  func approveActiveMCPApproval(taskID: String?) {
    guard let id = activeMCPApproval(taskID: taskID),
      let decision = preferredApprovalDecision(id) else { return }
    resolveMCPApproval(id, decision: decision)
  }

  func canApproveMCPApproval(taskID: String?) -> Bool {
    guard let id = activeMCPApproval(taskID: taskID) else { return false }
    return preferredApprovalDecision(id) != nil
  }

  func mcpApprovalCommands(taskID: String?, visible: Bool) -> MCPApprovalCommands? {
    guard visible, activeMCPApproval(taskID: taskID) != nil else { return nil }
    return MCPApprovalCommands(
      approve: { [weak self] in
        guard let self, let id = self.activeMCPApproval(taskID: taskID),
          let decision = self.preferredApprovalDecision(id) else { return }
        self.resolveMCPApproval(id, decision: decision)
      },
      decline: { [weak self] in self?.resolveActiveMCPApproval(taskID: taskID, decision: .deny) })
  }

  @discardableResult func handleMCPApprovalShortcut(
    _ binding: ShortcutBinding, taskID: String?, context: MCPApprovalKeyContext
  ) -> Bool {
    guard context.visible, !context.hasSheet, !context.isRepeat, !context.markedText,
      !context.ownsPanelInput, shortcutCaptureCount == 0, !restoringLibrary else { return false }
    let plainKey = !binding.command && !binding.control && !binding.option && !binding.shift
    guard !(plainKey && context.editingText), let id = activeMCPApproval(taskID: taskID) else { return false }
    if shortcuts.matches("approval-approve", binding), let decision = preferredApprovalDecision(id) {
      resolveMCPApproval(id, decision: decision); return true
    }
    if shortcuts.matches("approval-decline", binding) { resolveMCPApproval(id, decision: .deny); return true }
    return false
  }
}
