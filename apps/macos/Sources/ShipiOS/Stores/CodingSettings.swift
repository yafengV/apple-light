import Foundation

extension WorkspaceStore {
  func runtimePermissions(for taskID: String) -> AgentRuntimePreferences {
    library.taskRuntimePreferences[taskID] ?? library.agentRuntimePreferences
  }

  func composerRuntimePreferences(taskID: String?, draftKey: String) -> AgentRuntimePreferences {
    if let taskID { return runtimePermissions(for: taskID) }
    return library.newTaskRuntimePreferences[draftKey] ?? library.agentRuntimePreferences
  }

  @discardableResult func saveComposerRuntimePreferences(
    _ preferences: AgentRuntimePreferences?, taskID: String?, draftKey: String
  ) -> Bool {
    guard libraryLoaded else { return false }
    if let taskID, !library.tasks.contains(where: { $0.id == taskID }) { return false }
    let current = composerRuntimePreferences(taskID: taskID, draftKey: draftKey)
    guard preferences?.sandboxMode != .fullAccess || library.showFullAccessInComposer
      || current.sandboxMode == .fullAccess else { return false }
    do {
      var candidate = library
      if let taskID { candidate.taskRuntimePreferences[taskID] = preferences }
      else { candidate.newTaskRuntimePreferences[draftKey] = preferences }
      try commitLibrary(candidate)
      error = nil
      return true
    } catch {
      self.error = "无法保存输入区权限：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func savePopoutHomeRuntimePreferences(
    _ preferences: AgentRuntimePreferences?) -> Bool {
    guard libraryLoaded else { return false }
    guard preferences?.sandboxMode != .fullAccess || library.showFullAccessInComposer else {
      return false
    }
    do {
      var candidate = library
      candidate.popoutHomeRuntimePreferences = preferences
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = error.localizedDescription
      return false
    }
  }

  @discardableResult func saveAgentRuntimePreferences(_ preferences: AgentRuntimePreferences) -> Bool {
    guard preferences.sandboxMode != .fullAccess || library.showFullAccessInComposer else {
      return false
    }
    let previous = library.agentRuntimePreferences
    library.agentRuntimePreferences = preferences
    if saveLibrary() { return true }
    library.agentRuntimePreferences = previous
    return false
  }

  /// Showing the option does not select it. Hiding it removes Full Access only from
  /// future task defaults; already-created task snapshots remain unchanged.
  @discardableResult func saveShowFullAccessInComposer(_ visible: Bool) -> Bool {
    guard libraryLoaded else { return false }
    do {
      var candidate = library
      candidate.showFullAccessInComposer = visible
      if !visible {
        if candidate.agentRuntimePreferences.sandboxMode == .fullAccess {
          candidate.agentRuntimePreferences.sandboxMode = .workspaceWrite
          candidate.agentRuntimePreferences.networkAccess = false
        }
        if candidate.popoutHomeRuntimePreferences?.sandboxMode == .fullAccess {
          candidate.popoutHomeRuntimePreferences?.sandboxMode = .workspaceWrite
          candidate.popoutHomeRuntimePreferences?.networkAccess = false
        }
        for key in Array(candidate.newTaskRuntimePreferences.keys) {
          if candidate.newTaskRuntimePreferences[key]?.sandboxMode == .fullAccess {
            candidate.newTaskRuntimePreferences[key]?.sandboxMode = .workspaceWrite
            candidate.newTaskRuntimePreferences[key]?.networkAccess = false
          }
        }
      }
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = error.localizedDescription
      return false
    }
  }

  @discardableResult func saveAgentResponsePreferences(_ preferences: AgentResponsePreferences) -> Bool {
    let previous = library.agentResponsePreferences
    library.agentResponsePreferences = preferences
    if saveLibrary() { return true }
    library.agentResponsePreferences = previous
    return false
  }

  @discardableResult func saveAgentWebSearchMode(_ mode: AgentWebSearchMode) -> Bool {
    let previous = library.agentWebSearchMode
    library.agentWebSearchMode = mode
    if saveLibrary() { return true }
    library.agentWebSearchMode = previous
    return false
  }

  @discardableResult func saveAdvancedReasoningEfforts(_ efforts: Set<AgentAdvancedReasoningEffort>) -> Bool {
    let previous = library.enabledAdvancedReasoningEfforts
    library.enabledAdvancedReasoningEfforts = efforts
    if saveLibrary() { return true }
    library.enabledAdvancedReasoningEfforts = previous
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
      try configuration.validateEndpoint()
      let key = try ModelKeychain.read(account: configuration.credentialAccount)
      guard let repository = workspace.gitRoot else { return }
      let generate = GitTextGenerator.make(config: configuration, key: key, repository: repository,
        dataRoot: dataRoot, executable: executable)
      workspace.generateCommitMessage(config: configuration, key: key,
        instructions: library.gitPreferences.commitInstructions, includeUnstaged: includeUnstaged,
        generate: generate)
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
