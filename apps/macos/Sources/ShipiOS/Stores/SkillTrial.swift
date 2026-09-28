import Foundation

extension WorkspaceStore {
  func canTrySkill(_ id: String, projectPath: String? = nil) -> Bool {
    let context = projectPath ?? currentProjectKey
    guard projectPath == nil || skillLibraryProjectPaths.contains(context) else { return false }
    return libraryLoaded && !restoringLibrary && !busy && !skillTrialInProgress
      && !importingImages && !importingFiles && pluginsLoaded
      && (context == currentProjectKey || activeLocalRun == nil)
      && !handoffBlocksProject(context)
      && composerSkills(for: context).contains { $0.id == id }
  }

  @discardableResult func trySkill(_ id: String, projectPath: String?) async -> Bool {
    guard let target = projectPath, target != currentProjectKey else { return trySkill(id) }
    guard canTrySkill(id, projectPath: target) else {
      pluginsError = "技能当前不可用，或所属项目不能切换。"
      return false
    }
    skillTrialInProgress = true
    defer { skillTrialInProgress = false }
    let previousProject = currentProjectKey, previousDestination = destination
    do {
      let preferences = try PluginStorage.load(root: dataRoot)
      let available = try PluginStorage.skills(preferences: preferences, root: dataRoot)
        + PluginStorage.repositorySkills(project: URL(fileURLWithPath: target, isDirectory: true))
          .filter { preferences.isSkillEnabled($0) }
      guard let requested = available.first(where: { $0.id == id }) else {
        throw AgentFailure(message: "项目技能已停用或移除，请重新加载技能。")
      }
      let canonicalTarget = URL(fileURLWithPath: target, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
      recordNavigation()
      guard await openTaskScope(canonicalTarget), !Task.isCancelled, !shuttingDown else {
        throw AgentFailure(message: "无法打开技能所属项目，未创建任务。")
      }
      let updated = try PluginStorage.skills(preferences: PluginStorage.load(root: dataRoot), root: dataRoot)
        + PluginStorage.repositorySkills(project: URL(fileURLWithPath: currentProjectKey, isDirectory: true))
      guard let resolved = updated.first(where: {
        $0.sourceFileURL == requested.sourceFileURL
      }) else { throw AgentFailure(message: "技能已移除，未创建任务。") }
      skillTrialInProgress = false
      guard trySkill(resolved.id, recordHistory: false) else {
        throw AgentFailure(message: pluginsError ?? "无法创建技能任务。")
      }
      return true
    } catch {
      skillTrialInProgress = true
      if !shuttingDown, currentProjectKey != previousProject {
        _ = await openTaskScope(previousProject)
        destination = previousDestination
      }
      pluginsError = error.localizedDescription
      return false
    }
  }

  @discardableResult func trySkill(_ id: String, recordHistory: Bool = true) -> Bool {
    guard canTrySkill(id) else {
      pluginsError = "技能当前不可用。请确认技能及其插件已启用，并等待工作区完成加载。"
      return false
    }
    do {
      // Recheck the installed state before creating anything; a preview may be stale.
      let preferences = try PluginStorage.load(root: dataRoot)
      let repository = currentProjectKey.isEmpty ? [] : try PluginStorage.repositorySkills(
        project: URL(fileURLWithPath: currentProjectKey, isDirectory: true))
      let skills = try PluginStorage.skills(preferences: preferences, root: dataRoot)
        + repository.filter { preferences.isSkillEnabled($0) }
      guard let skill = skills.first(where: { $0.id == id }) else {
        throw AgentFailure(message: "技能已被停用或移除，请重新加载插件。")
      }
      let now = Date()
      let task = WorkspaceTask(id: UUID().uuidString, project: currentProjectKey,
        title: "新任务", runIDs: [], createdAt: now, updatedAt: now)
      var candidate = library
      candidate.tasks.insert(task, at: 0)
      candidate.drafts[task.id] = skill.trialPrompt
      candidate.projectSelections[currentProjectKey] = task.id
      candidate.lastWorkspace = currentProjectKey
      try commitLibrary(candidate)
      if recordHistory { recordNavigation() }
      returnToWorkspace()
      dismissCodeReviewMode()
      action = .chat
      applyTaskSelection(task)
      pluginsError = nil
      return true
    } catch {
      pluginsError = "无法新建技能任务：\(error.localizedDescription)"
      return false
    }
  }
}
