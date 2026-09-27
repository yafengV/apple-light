import AppKit
import Foundation

extension WorkspaceStore {
  func openDeepLink(_ link: ShipiOSDeepLink) async {
    switch link {
    case .workspace: returnToWorkspace()
    case .projects: showProjects()
    case .plugins: showPlugins()
    case .skills: showSkills()
    case .plugin(let id):
      showPlugins()
      if pluginPreferences.installed.contains(where: { $0.id == id }) { openPluginDetail(id) }
    case .automations: showAutomations(create: true)
    case .automationsList: showAutomations()
    case .newTask(let prompt, let path, let originURL):
      await openNewTaskDeepLink(prompt: prompt, path: path, originURL: originURL)
    case .settings(let page): openSettings(page)
    case .connectionSettings(let section):
      openSettings(.connections)
      if destination == .settings && settingsPage == .connections {
        connectionSettingsSection = section
      }
    case .task(let id):
      guard let task = library.tasks.first(where: { $0.id == id || $0.runIDs.contains(id) }) else {
        error = "找不到深链接指定的任务。"
        return
      }
      guard canSelectTask(task) else {
        error = "当前任务仍在运行，暂时无法打开深链接中的其他任务。"
        return
      }
      if task.project == currentProjectKey { applyTaskSelection(task) }
      else if await openTaskScope(task.project) { applyTaskSelection(task) }
    }
  }

  private func openNewTaskDeepLink(prompt: String?, path: String?, originURL: String?) async {
    guard libraryLoaded, !busy, activeLocalRun == nil else {
      error = "当前工作区尚未就绪，无法打开新任务链接。"
      return
    }
    var target: String?
    if let path {
      guard path.hasPrefix("/"), !path.utf8.contains(0) else {
        error = "新任务链接中的项目路径必须是本地绝对路径。"
        return
      }
      let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
        isDirectory.boolValue else {
        error = "新任务链接中的项目目录不存在。"
        return
      }
      target = canonical.path
    } else if let originURL {
      for candidate in library.orderedProjects {
        guard let remote = try? await GitReviewService.checked(
          ["remote", "get-url", "origin"], at: URL(fileURLWithPath: candidate)) else { continue }
        if remote.trimmingCharacters(in: .whitespacesAndNewlines) == originURL {
          target = candidate
          break
        }
      }
      guard target != nil else {
        error = "找不到与链接 Git 远端匹配的已保存项目。"
        return
      }
    } else if let current = project?.path,
      let managed = library.managedWorktrees.first(where: { $0.path == current }) {
      target = managed.source
    }
    if let selected = target, let managed = library.managedWorktrees.first(where: { $0.path == selected }) {
      target = managed.source
    }
    if let target { await newTask(in: target) }
    else { await newChat() }
    guard destination == .workspace, selectedTask == nil,
      target == nil || project?.path == target else {
      error = error ?? "无法打开新任务链接。"
      return
    }
    library.linkedNewTaskDraftIDs[currentProjectKey] = UUID()
    draft = prompt ?? ""
    focusComposer = UUID()
  }

  func copyTaskDeepLink(_ task: WorkspaceTask) {
    guard let value = ShipiOSDeepLink.task(task.id).url?.absoluteString else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  func recordCodexThreadID(taskID: String, threadID: String) {
    guard UUID(uuidString: threadID) != nil,
      let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      library.tasks[index].codexThreadID != threadID else { return }
    library.tasks[index].codexThreadID = threadID
    saveLibrary()
  }

  func copyCodexSessionID(_ task: WorkspaceTask) {
    guard let threadID = library.tasks.first(where: { $0.id == task.id })?.copyableCodexThreadID
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(threadID, forType: .string)
  }

  func codexConversationPath(for task: WorkspaceTask) -> URL? {
    CodexConversationPath.existingPath(task: task, dataRoot: dataRoot)
  }

  func copyCodexConversationPath(_ task: WorkspaceTask, to pasteboard: NSPasteboard = .general) {
    guard let path = codexConversationPath(for: task) else { return }
    pasteboard.clearContents()
    pasteboard.setString(path.path, forType: .string)
  }
}
