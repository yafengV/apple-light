import Foundation

extension WorkspaceStore {
  func popoutEnvironmentSelection(project: String) -> String {
    let sourcePath = library.primaryFolder(for: project)
    if let taskID = library.pendingPopoutWorktreeTaskIDs[sourcePath],
      let record = library.managedWorktrees.first(where: { $0.taskID == taskID }),
      let environment = record.environment {
      return environment.disabled ? WorktreeEnvironmentChoice.none
        : (environment.fileName ?? WorktreeEnvironmentChoice.legacy)
    }
    return library.newTaskEnvironmentSelections[sourcePath]
      ?? AutomationEnvironmentChoice.projectDefault
  }

  @discardableResult func setPopoutEnvironmentSelection(_ selection: String,
    project: String) -> Bool {
    guard libraryLoaded, library.isKnownProjectScope(project)
      || library.projects.contains(project) else { return false }
    let sourcePath = library.primaryFolder(for: project)
    guard library.pendingPopoutWorktreeTaskIDs[sourcePath] == nil else {
      generalSettingsError = "已有待恢复的弹出窗口工作树，环境不能再更改。"
      return false
    }
    let builtIn = [AutomationEnvironmentChoice.projectDefault,
      WorktreeEnvironmentChoice.none, WorktreeEnvironmentChoice.legacy]
    guard builtIn.contains(selection) || environmentCatalog[project]?.contains(where: {
      $0.id == selection && $0.error == nil
    }) == true else {
      generalSettingsError = "所选项目环境已不可用，请刷新环境列表。"
      return false
    }
    do {
      var candidate = library
      candidate.newTaskEnvironmentSelections[sourcePath] =
        selection == AutomationEnvironmentChoice.projectDefault ? nil : selection
      try commitLibrary(candidate)
      generalSettingsError = nil
      return true
    } catch {
      generalSettingsError = error.localizedDescription
      return false
    }
  }

  /// Keep the home composer intact until a detached checkout and its setup both succeed.
  func preparePopoutWorktreeTask(prompt: String, project selectedProject: String) async -> WorkspaceTask? {
    guard libraryLoaded, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !popoutHomeImages.isEmpty || !popoutHomeFiles.isEmpty else { return nil }
    guard !busy, !managedTaskPreparing, activeLocalRun == nil else {
      generalSettingsError = "请等待当前工作区操作完成后重试。"
      return nil
    }
    guard library.isKnownProjectScope(selectedProject)
      || selectedProject == currentProjectKey
      || selectedProject == library.projectOwner(for: currentProjectKey) else {
      generalSettingsError = "所选项目已不可用，请重新选择项目。"
      return nil
    }
    let sourcePath = library.primaryFolder(for: selectedProject)
    let submittedImages = popoutHomeImages
    let submittedFiles = popoutHomeFiles
    do {
      _ = try ProjectFolders.canonical([sourcePath])
      let config = modelConfiguration(for: nil)
      guard config.apiProtocol == .codexResponses else {
        throw AgentFailure(message: "工作树任务需要在设置 → 模型与 API 中选择 Codex Core · Responses。")
      }
      try config.validateEndpoint()
      guard !config.model.isEmpty else {
        throw AgentFailure(message: "请先在设置 → 模型与 API 中配置独立服务和模型。")
      }
      guard personalizationLoaded, memoryError == nil else {
        throw AgentFailure(message: "个人指令或记忆尚未加载完成，请在设置中检查。")
      }
      _ = try ModelKeychain.read(account: config.credentialAccount)

      let taskID = library.pendingPopoutWorktreeTaskIDs[sourcePath] ?? UUID().uuidString
      if library.pendingPopoutWorktreeTaskIDs[sourcePath] == nil {
        var pending = library
        pending.pendingPopoutWorktreeTaskIDs[sourcePath] = taskID
        try commitLibrary(pending)
      }
      let record = try await prepareDetachedManagedWorktree(sourcePath: sourcePath,
        taskID: taskID,
        environmentSelection: library.newTaskEnvironmentSelections[sourcePath]
          ?? AutomationEnvironmentChoice.projectDefault,
        purpose: "弹出窗口任务")
      guard record.ready, record.source == GitBranchService.canonicalRoot(
        URL(fileURLWithPath: sourcePath)).path else {
        throw AgentFailure(message: "弹出窗口工作树尚未准备完成，请重试。")
      }
      var candidate = library
      guard candidate.pendingPopoutWorktreeTaskIDs[sourcePath] == taskID,
        !candidate.tasks.contains(where: { $0.id == taskID }) else {
        throw AgentFailure(message: "弹出窗口任务已变化，请重试。")
      }
      guard candidate.drafts[Self.popoutHomeDraftKey] == prompt,
        (candidate.draftImages[Self.popoutHomeDraftKey] ?? []) == submittedImages,
        (candidate.draftFiles[Self.popoutHomeDraftKey] ?? []) == submittedFiles else {
        throw AgentFailure(message: "弹出窗口草稿已变化；工作树已准备好，请重新发送。")
      }
      let now = Date()
      let task = WorkspaceTask(id: taskID, project: record.path, title: "新任务",
        runIDs: [], popoutDraft: true, createdAt: now, updatedAt: now)
      candidate.tasks.insert(task, at: 0)
      candidate.drafts[taskID] = prompt
      candidate.draftImages[taskID] = candidate.draftImages[Self.popoutHomeDraftKey]
      candidate.draftFiles[taskID] = candidate.draftFiles[Self.popoutHomeDraftKey]
      candidate.drafts[Self.popoutHomeDraftKey] = nil
      candidate.draftImages[Self.popoutHomeDraftKey] = nil
      candidate.draftFiles[Self.popoutHomeDraftKey] = nil
      candidate.pendingPopoutWorktreeTaskIDs[sourcePath] = nil
      candidate.projectSelections[record.path] = taskID
      var profile = candidate.profiles[record.source] ?? BuildProfile()
      record.environment?.apply(to: &profile)
      candidate.profiles[record.path] = profile
      try commitLibrary(candidate)
      generalSettingsError = nil
      return task
    } catch {
      generalSettingsError = error.localizedDescription
      return nil
    }
  }
}
