import Foundation

extension WorkspaceStore {
  func canTrySkill(_ id: String) -> Bool {
    libraryLoaded && !restoringLibrary && !busy && !importingImages && !importingFiles
      && pluginsLoaded && composerSkills.contains { $0.id == id }
  }

  @discardableResult func trySkill(_ id: String) -> Bool {
    guard canTrySkill(id) else {
      pluginsError = "技能当前不可用。请确认技能及其插件已启用，并等待工作区完成加载。"
      return false
    }
    do {
      // Recheck the installed state before creating anything; a preview may be stale.
      let preferences = try PluginStorage.load(root: dataRoot)
      let skills = try PluginStorage.skills(preferences: preferences, root: dataRoot)
      guard let skill = skills.first(where: { $0.id == id }) else {
        throw AgentFailure(message: "技能已被停用或移除，请重新加载插件。")
      }
      let now = Date()
      let task = WorkspaceTask(id: UUID().uuidString, project: currentProjectKey,
        title: "新任务", runIDs: [], createdAt: now, updatedAt: now)
      var candidate = library
      candidate.tasks.insert(task, at: 0)
      candidate.drafts[task.id] = skill.promptReference + " "
      candidate.projectSelections[currentProjectKey] = task.id
      candidate.lastWorkspace = currentProjectKey
      try commitLibrary(candidate)
      recordNavigation()
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
