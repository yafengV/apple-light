import Foundation

extension WorkspaceStore {
  /// Resolve a selected project's environment independently of the window's current project.
  func automationEnvironmentSnapshot(projectPath: String, selectionID: String,
    existing: ManagedEnvironmentSnapshot? = nil) async throws -> ManagedEnvironmentSnapshot {
    if let existing { return existing }
    let profile = library.profiles[projectPath] ?? BuildProfile()
    func legacy() -> ManagedEnvironmentSnapshot {
      ManagedEnvironmentSnapshot(fileName: nil, name: "ShipiOS 本地配置", disabled: false,
        setupScript: profile.worktreeSetupScript, setupPlatforms: profile.setupPlatformScripts,
        cleanupScript: profile.worktreeCleanupScript,
        cleanupPlatforms: profile.cleanupPlatformScripts, actions: profile.actions)
    }
    if selectionID == WorktreeEnvironmentChoice.legacy { return legacy() }
    if selectionID == WorktreeEnvironmentChoice.none { return .none }

    let project = URL(fileURLWithPath: projectPath, isDirectory: true)
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-automation-environment-\(UUID())", isDirectory: true)
    let browser = AgentClient()
    do {
      try browser.start(executable: executable, project: project, dataDirectory: temporary)
      _ = try await browser.request("initialize", ["protocolVersion": .number(1)])
      let entries = try await browser.request("environment.list")
        .decode([LocalEnvironmentEntry].self)
      let selected: String
      if selectionID == AutomationEnvironmentChoice.projectDefault {
        if let preference = library.newTaskEnvironmentSelections[projectPath],
          preference != AutomationEnvironmentChoice.projectDefault {
          selected = preference
        } else if let fileName = profile.environmentFileName {
          selected = fileName
        } else if let defaultFile = entries.first(where: {
          $0.fileName == "environment.toml" && !$0.inherited && $0.error == nil
        }) ?? entries.first(where: {
          $0.fileName == "environment.toml" && $0.error == nil
        }) {
          selected = defaultFile.id
        } else {
          selected = profile.macOSSetupScript.isEmpty && profile.macOSCleanupScript.isEmpty
            && profile.actions.isEmpty ? WorktreeEnvironmentChoice.none : WorktreeEnvironmentChoice.legacy
        }
      } else { selected = selectionID }
      let environment: ManagedEnvironmentSnapshot
      if selected == WorktreeEnvironmentChoice.none { environment = .none }
      else if selected == WorktreeEnvironmentChoice.legacy { environment = legacy() }
      else {
        guard entries.contains(where: { $0.id == selected && $0.error == nil }) else {
          throw AgentFailure(message: "计划任务所选环境已不可用，请在自动化编辑器中重新选择。")
        }
        let loaded = try await browser.request("environment.load", ["fileName": .string(selected)])
        environment = try decodeManagedEnvironment(selectionID: selected, loaded: loaded)
      }
      await browser.stop()
      try? FileManager.default.removeItem(at: temporary)
      return environment
    } catch {
      await browser.stop()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}
