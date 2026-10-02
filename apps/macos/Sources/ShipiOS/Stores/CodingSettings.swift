import Foundation

enum AgentPermissionProfileValidation {
  static func validate(_ profile: AgentNamedPermissionProfile, executable: URL,
    project: URL) async throws -> Bool {
    try await Task.detached(priority: .userInitiated) {
      let staged = FileManager.default.temporaryDirectory
        .appendingPathComponent("shipios-permissions-\(UUID().uuidString).toml")
      defer { try? FileManager.default.removeItem(at: staged) }
      try Data(profile.configTOML.utf8).write(to: staged, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
      let process = Process()
      process.executableURL = executable
      process.arguments = ["--project", project.path, "validate-permission-profile",
        "--id", profile.id, "--config-path", staged.path]
      let standardOutput = Pipe()
      let standardError = Pipe()
      process.standardOutput = standardOutput
      process.standardError = standardError
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let detail = String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
          as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentFailure(message: detail.isEmpty ? "Codex Core 拒绝此权限配置。" : detail)
      }
      struct Result: Decodable { var requiresFullAccess: Bool }
      let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
      return try JSONDecoder().decode(Result.self, from: data).requiresFullAccess
    }.value
  }
}

extension WorkspaceStore {
  private func snapshotInheritedTaskPermissions(_ candidate: inout WorkspaceLibrary) {
    for task in candidate.tasks where candidate.taskRuntimePreferences[task.id] == nil {
      candidate.taskRuntimePreferences[task.id] = candidate.agentRuntimePreferences
    }
  }

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
    guard preferences?.namedProfile.map({ profile in
      !profile.requiresFullAccess || library.showFullAccessInComposer
        || current.namedProfile == profile
    }) ?? true else { return false }
    guard preferences?.sandboxMode != .fullAccess || library.showFullAccessInComposer
      || current.sandboxMode == .fullAccess else { return false }
    guard preferences?.approvalReviewer != .autoReview || library.showAutoReviewInComposer
      || current.approvalReviewer == .autoReview else { return false }
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
    guard preferences?.namedProfile.map({ profile in
      !profile.requiresFullAccess || library.showFullAccessInComposer
        || library.popoutHomeRuntimePreferences?.namedProfile == profile
    }) ?? true else { return false }
    guard preferences?.sandboxMode != .fullAccess || library.showFullAccessInComposer else {
      return false
    }
    guard preferences?.approvalReviewer != .autoReview || library.showAutoReviewInComposer else {
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
    guard preferences.namedProfile?.requiresFullAccess != true
      || library.showFullAccessInComposer else { return false }
    guard preferences.namedProfile.map({ named in
      library.namedPermissionProfiles.contains(named)
    }) ?? true else { return false }
    guard preferences.sandboxMode != .fullAccess || library.showFullAccessInComposer else {
      return false
    }
    guard preferences.approvalReviewer != .autoReview || library.showAutoReviewInComposer else {
      return false
    }
    guard libraryLoaded else { return false }
    do {
      var candidate = library
      snapshotInheritedTaskPermissions(&candidate)
      candidate.agentRuntimePreferences = preferences
      try commitLibrary(candidate)
      error = nil
      return true
    } catch {
      self.error = "无法保存默认权限：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func validateAndSaveNamedPermissionProfile(
    _ profile: AgentNamedPermissionProfile
  ) async -> Bool {
    guard libraryLoaded else { return false }
    guard profile.hasValidShape else {
      generalSettingsError = "档案 ID、说明或配置长度不符合要求。"
      return false
    }
    do {
      let project: URL
      if let root = workspace.root, FileManager.default.fileExists(atPath: root.path) {
        project = root
      } else {
        project = dataRoot
      }
      var validated = profile
      validated.requiresFullAccess = try await AgentPermissionProfileValidation.validate(profile,
        executable: executable, project: project)
      var candidate = library
      if let index = candidate.namedPermissionProfiles.firstIndex(where: { $0.id == profile.id }) {
        candidate.namedPermissionProfiles[index] = validated
      } else {
        candidate.namedPermissionProfiles.append(validated)
      }
      if candidate.agentRuntimePreferences.namedProfile?.id == profile.id {
        snapshotInheritedTaskPermissions(&candidate)
        if !validated.requiresFullAccess || candidate.showFullAccessInComposer {
          candidate.agentRuntimePreferences.namedProfile = validated
        } else {
          candidate.agentRuntimePreferences = .askForApproval
        }
      }
      if candidate.popoutHomeRuntimePreferences?.namedProfile?.id == profile.id {
        if !validated.requiresFullAccess || candidate.showFullAccessInComposer {
          candidate.popoutHomeRuntimePreferences?.namedProfile = validated
        } else {
          candidate.popoutHomeRuntimePreferences = nil
        }
      }
      for key in Array(candidate.newTaskRuntimePreferences.keys)
        where candidate.newTaskRuntimePreferences[key]?.namedProfile?.id == profile.id {
        if !validated.requiresFullAccess || candidate.showFullAccessInComposer {
          candidate.newTaskRuntimePreferences[key]?.namedProfile = validated
        } else {
          candidate.newTaskRuntimePreferences.removeValue(forKey: key)
        }
      }
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = "无法保存命名权限档案：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func deleteNamedPermissionProfile(_ id: String) -> Bool {
    guard libraryLoaded, library.namedPermissionProfiles.contains(where: { $0.id == id }) else {
      return false
    }
    do {
      var candidate = library
      candidate.namedPermissionProfiles.removeAll { $0.id == id }
      if candidate.agentRuntimePreferences.namedProfile?.id == id {
        snapshotInheritedTaskPermissions(&candidate)
        candidate.agentRuntimePreferences = .askForApproval
      }
      if candidate.popoutHomeRuntimePreferences?.namedProfile?.id == id {
        candidate.popoutHomeRuntimePreferences = nil
      }
      for key in Array(candidate.newTaskRuntimePreferences.keys)
        where candidate.newTaskRuntimePreferences[key]?.namedProfile?.id == id {
        candidate.newTaskRuntimePreferences.removeValue(forKey: key)
      }
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = "无法删除命名权限档案：\(error.localizedDescription)"
      return false
    }
  }

  /// Availability changes affect future defaults and drafts. Existing task
  /// snapshots keep their selected reviewer, as with Full Access.
  @discardableResult func saveShowAutoReviewInComposer(_ visible: Bool) -> Bool {
    guard libraryLoaded else { return false }
    do {
      var candidate = library
      candidate.showAutoReviewInComposer = visible
      if !visible {
        if candidate.agentRuntimePreferences.approvalReviewer == .autoReview {
          snapshotInheritedTaskPermissions(&candidate)
          candidate.agentRuntimePreferences = .askForApproval
        }
        if candidate.popoutHomeRuntimePreferences?.approvalReviewer == .autoReview {
          candidate.popoutHomeRuntimePreferences = .askForApproval
        }
        for key in Array(candidate.newTaskRuntimePreferences.keys) {
          if candidate.newTaskRuntimePreferences[key]?.approvalReviewer == .autoReview {
            candidate.newTaskRuntimePreferences[key] = .askForApproval
          }
        }
      }
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = "无法保存自动审查设置：\(error.localizedDescription)"
      return false
    }
  }

  /// Showing the option does not select it. Hiding it removes Full Access only from
  /// future task defaults; already-created task snapshots remain unchanged.
  @discardableResult func saveShowFullAccessInComposer(_ visible: Bool) -> Bool {
    guard libraryLoaded else { return false }
    do {
      var candidate = library
      candidate.showFullAccessInComposer = visible
      if !visible {
        if candidate.agentRuntimePreferences.sandboxMode == .fullAccess
          || candidate.agentRuntimePreferences.namedProfile?.requiresFullAccess == true {
          snapshotInheritedTaskPermissions(&candidate)
          candidate.agentRuntimePreferences = .askForApproval
        }
        if candidate.popoutHomeRuntimePreferences?.sandboxMode == .fullAccess
          || candidate.popoutHomeRuntimePreferences?.namedProfile?.requiresFullAccess == true {
          candidate.popoutHomeRuntimePreferences = .askForApproval
        }
        for key in Array(candidate.newTaskRuntimePreferences.keys) {
          if candidate.newTaskRuntimePreferences[key]?.sandboxMode == .fullAccess
            || candidate.newTaskRuntimePreferences[key]?.namedProfile?.requiresFullAccess == true {
            candidate.newTaskRuntimePreferences[key] = .askForApproval
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
      workspace.gitReviewLastTurnOnly = normalized.disableGitBasedReview
      for sessions in additionalTaskWindowPanels.allObjects {
        for panel in sessions.tasks.values {
          panel.workspace.gitReviewLastTurnOnly = normalized.disableGitBasedReview
        }
      }
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
    workspace.selectedReviewScope = library.gitPreferences.defaultReviewScope
    openReviewTab()
  }
}
