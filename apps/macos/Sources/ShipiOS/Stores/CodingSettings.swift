import Foundation

extension WorkspaceStore {
  @discardableResult func saveAgentRuntimePreferences(_ preferences: AgentRuntimePreferences) -> Bool {
    let previous = library.agentRuntimePreferences
    library.agentRuntimePreferences = preferences
    if saveLibrary() { return true }
    library.agentRuntimePreferences = previous
    return false
  }

  @discardableResult func saveAgentResponsePreferences(_ preferences: AgentResponsePreferences) -> Bool {
    let previous = library.agentResponsePreferences
    library.agentResponsePreferences = preferences
    if saveLibrary() { return true }
    library.agentResponsePreferences = previous
    return false
  }

  func gitCommitTaskTitle(taskID: String?) -> String? {
    if let taskID { return library.tasks.first { $0.id == taskID }?.title }
    return selectedTask?.title
  }

  func setDefaultTerminalLocation(_ placement: WorkspaceTabPlacement) {
    guard placement == .right || placement == .bottom else { return }
    library.defaultTerminalLocation = placement
    saveLibrary()
  }

  @discardableResult func saveGitPreferences(_ preferences: GitPreferences) -> Bool {
    var normalized = preferences
    normalized.normalize()
    guard normalized.commitInstructions.utf8.count <= 16_384 else {
      error = "提交指令不能超过 16 KiB。"
      return false
    }
    guard normalized.pullRequestInstructions.utf8.count <= 16_384 else {
      error = "PR 指令不能超过 16 KiB。"
      return false
    }
    var candidate = library
    candidate.gitPreferences = normalized
    do {
      try commitLibrary(candidate)
      return true
    } catch { self.error = "无法保存 Git 设置：\(error.localizedDescription)"; return false }
  }

  func generateCommitMessage(in workspace: DeveloperWorkspace, includeUnstaged: Bool = false) {
    guard !library.gitPreferences.readOnlyReview, !workspace.generatingCommitMessage else { return }
    do {
      let configuration = modelConfiguration
      _ = try configuration.endpoint("chat/completions")
      let key = try ModelKeychain.read(account: configuration.credentialAccount)
      workspace.generateCommitMessage(config: configuration, key: key,
        instructions: library.gitPreferences.commitInstructions, includeUnstaged: includeUnstaged)
    } catch { workspace.commitGenerationError = error.localizedDescription }
  }

  func openReviewFromSettings() {
    guard project != nil else { return }
    closeSettings()
    destination = .workspace
    workspace.reviewScope = library.gitPreferences.defaultReviewScope
    openReviewTab()
  }
}
