import AppKit
import CryptoKit
import Foundation

extension WorkspaceStore {
  var pluginsEnabled: Bool {
    get { library.pluginsEnabled }
    set {
      updateGeneralPreference(\.pluginsEnabled, value: newValue)
      reconcilePluginSettingsTarget()
    }
  }

  var showInMenuBar: Bool {
    get { library.showInMenuBar }
    set { updateGeneralPreference(\.showInMenuBar, value: newValue) }
  }

  var showEducationalTips: Bool {
    get { library.showEducationalTips }
    set { updateGeneralPreference(\.showEducationalTips, value: newValue) }
  }

  func educationalTip(taskID: String?) -> ComposerEducationalTip? {
    guard showEducationalTips else { return nil }
    let hasActiveRun = taskID.map { activeRun(taskID: $0) != nil } ?? (selectedActiveRun != nil)
    return ComposerEducationalTip.supported.first { tip in
      !library.dismissedEducationalTipIDs.contains(tip.id)
        && (tip.id != ComposerEducationalTip.steering.id || hasActiveRun)
    }
  }

  func dismissEducationalTip(_ id: String) {
    var dismissed = library.dismissedEducationalTipIDs
    dismissed.insert(id)
    updateGeneralPreference(\.dismissedEducationalTipIDs, value: dismissed)
  }

  /// Returns true when the action belongs in the main window.
  @discardableResult func performEducationalTip(_ tip: ComposerEducationalTip, taskID: String?) -> Bool {
    dismissEducationalTip(tip.id)
    switch tip.action {
    case .prefill(let prompt):
      if let taskID {
        setTaskWindowDraft(
          Self.appendingEducationalPrompt(prompt, to: taskWindowDraft(taskID)), taskID: taskID)
      } else {
        draft = Self.appendingEducationalPrompt(prompt, to: draft)
        focusComposer = UUID()
      }
      return false
    case .settings(let page):
      openSettings(page)
      return true
    case .plugins:
      showPlugins()
      return true
    case .automations:
      showAutomations()
      return true
    case .newTask:
      newTask()
      return true
    }
  }

  static func appendingEducationalPrompt(_ prompt: String, to draft: String) -> String {
    guard !draft.isEmpty else { return prompt }
    if draft.last?.isWhitespace == true { return draft + prompt }
    return draft + " " + prompt
  }

  var showContextUsageIndicator: Bool {
    get { library.showContextUsageIndicator }
    set { updateGeneralPreference(\.showContextUsageIndicator, value: newValue) }
  }

  var showBottomPanelControl: Bool {
    get { library.showBottomPanelControl }
    set { updateGeneralPreference(\.showBottomPanelControl, value: newValue) }
  }

  var composerPlainTextMode: Bool {
    get { library.composerPlainTextMode }
    set { updateGeneralPreference(\.composerPlainTextMode, value: newValue) }
  }

  var webLinkTarget: WebLinkTarget {
    get { library.webLinkTarget }
    set { updateGeneralPreference(\.webLinkTarget, value: newValue) }
  }

  var popoutWindowProjectlessDefault: Bool {
    get { library.popoutWindowProjectlessDefault }
    set { updateGeneralPreference(\.popoutWindowProjectlessDefault, value: newValue) }
  }

  func createPopoutTask() -> WorkspaceTask? {
    guard libraryLoaded else {
      generalSettingsError = "工作区尚未完成加载，请稍后再新建窗口。"
      return nil
    }
    let project = popoutWindowProjectlessDefault ? "" : currentProjectKey
    let now = Date()
    let task = WorkspaceTask(
      id: UUID().uuidString, project: project, title: "新任务", runIDs: [], popoutDraft: true,
      createdAt: now, updatedAt: now)
    do {
      var candidate = library
      candidate.tasks.insert(task, at: 0)
      candidate.drafts[task.id] = ""
      try commitLibrary(candidate)
      generalSettingsError = nil
      return task
    } catch {
      generalSettingsError = "无法创建弹出任务：\(error.localizedDescription)"
      return nil
    }
  }

  func discardPopoutTaskIfEmpty(_ taskID: String) {
    guard let task = library.tasks.first(where: { $0.id == taskID }),
      task.isPopoutDraft, task.runIDs.isEmpty, activeRun(taskID: taskID) == nil
    else { return }
    do {
      var candidate = library
      candidate.tasks.removeAll { $0.id == taskID }
      candidate.drafts[taskID] = nil
      candidate.draftImages[taskID] = nil
      candidate.draftFiles[taskID] = nil
      candidate.reviewComments[taskID] = nil
      candidate.browserComments[taskID] = nil
      candidate.goalSessions[taskID] = nil
      candidate.projectlessTaskDirectories[taskID] = nil
      try commitLibrary(candidate)
    } catch { self.error = "无法清理未发送的弹出任务：\(error.localizedDescription)" }
  }

  var projectlessWorkspaceRoot: URL {
    if let path = library.projectlessWorkspaceRoot, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return dataRoot.appendingPathComponent("Projectless", isDirectory: true)
  }

  func setProjectlessWorkspaceRoot(_ url: URL?) {
    guard libraryLoaded else {
      generalSettingsError = "工作区尚未完成加载，请稍后再修改。"
      return
    }
    do {
      let path: String?
      if let url {
        guard url.path.hasPrefix("/") else {
          throw AgentFailure(message: "无项目任务文件夹必须是绝对路径。")
        }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory) {
          guard isDirectory.boolValue else {
            throw AgentFailure(message: "所选位置不是文件夹。")
          }
        } else {
          try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        }
        path = canonical.path
      } else {
        path = nil
      }
      var candidate = library
      candidate.projectlessWorkspaceRoot = path
      try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
      library = candidate
      generalSettingsError = nil
    } catch { generalSettingsError = error.localizedDescription }
  }

  func chooseProjectlessWorkspaceRoot() {
    let panel = NSOpenPanel()
    panel.title = "选择无项目任务文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = projectlessWorkspaceRoot
    guard let window = NSApp.keyWindow else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in self?.setProjectlessWorkspaceRoot(url) }
    }
  }

  func projectlessWorkspace(taskID: String, create: Bool) throws -> URL {
    if let path = library.projectlessTaskDirectories[taskID], !path.isEmpty {
      let directory = URL(fileURLWithPath: path, isDirectory: true)
      if create {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      return directory
    }
    let digest = SHA256.hash(data: Data(taskID.utf8)).map { String(format: "%02x", $0) }
      .joined().prefix(16)
    let directory = projectlessWorkspaceRoot.appendingPathComponent(String(digest), isDirectory: true)
    if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return directory
  }

  func workspaceRoot(for run: AgentRun) -> URL? {
    if !run.project.isEmpty { return URL(fileURLWithPath: run.project, isDirectory: true) }
    if let taskID = library.task(containing: run.id)?.id,
      let path = library.projectlessTaskDirectories[taskID], !path.isEmpty
    {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    if let path = run.request["workspace"].text, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return nil
  }

  var composerPlugins: [PluginInstallation] {
    pluginsEnabled ? pluginPreferences.installed : []
  }

  var composerSkills: [PluginSkillReference] {
    guard pluginsEnabled else { return [] }
    return pluginSkills.filter { skill in
      !pluginPreferences.disabledSkillIDs.contains(skill.id)
        && (skill.isStandalone || pluginPreferences.installed.contains { $0.id == skill.pluginID && $0.enabled })
    }
  }

  var activePluginPreferences: PluginPreferences {
    pluginsEnabled ? pluginPreferences : PluginPreferences()
  }

  func contextInputTokens(taskID: String?) -> Int? {
    let owner = taskID.flatMap { id in library.tasks.first(where: { $0.id == id }) }
      ?? selectedTask
    guard let owner else { return nil }
    let available = Dictionary(
      (runs + library.localRuns).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return owner.runIDs.reversed().compactMap { id -> Int? in
      guard let run = available[id], run.kind == "chat", let result = run.result,
        let usage = ModelTokenUsage(stored: result["usage"])
      else { return nil }
      return usage.inputTokens
    }.first
  }

  var followUpBehavior: FollowUpBehavior {
    get { library.followUpBehavior }
    set {
      guard libraryLoaded else {
        generalSettingsError = "工作区尚未完成加载，请稍后再修改。"
        return
      }
      do {
        var candidate = library
        candidate.followUpBehavior = newValue
        try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
        library = candidate
        generalSettingsError = nil
      } catch { generalSettingsError = error.localizedDescription }
    }
  }

  var preventIdleSleep: Bool {
    get { library.preventIdleSleep }
    set {
      guard libraryLoaded else {
        sleepPrevention.error = "工作区尚未完成加载，请稍后再修改。"
        return
      }
      do {
        var candidate = library
        candidate.preventIdleSleep = newValue
        try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
        library = candidate
        updateSleepPrevention(force: true)
      } catch { sleepPrevention.error = error.localizedDescription }
    }
  }

  func updateSleepPrevention(force: Bool = false) {
    let running = !shuttingDown && runs.contains {
      $0.isActive && $0.kind != "chat" && connected
    } || (!shuttingDown && hasLiveModelRequests)
    sleepPrevention.update(enabled: preventIdleSleep, hasRunningWork: running, force: force)
  }

  private func updateGeneralPreference<Value: Equatable>(
    _ keyPath: WritableKeyPath<WorkspaceLibrary, Value>, value: Value
  ) {
    // AppKit can echo MenuBarExtra's current insertion state during scene updates.
    // Publishing that identical value starts another scene update and callback.
    guard library[keyPath: keyPath] != value else { return }
    guard libraryLoaded else {
      generalSettingsError = "工作区尚未完成加载，请稍后再修改。"
      return
    }
    do {
      var candidate = library
      candidate[keyPath: keyPath] = value
      try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
      library = candidate
      generalSettingsError = nil
    } catch { generalSettingsError = error.localizedDescription }
  }
}
