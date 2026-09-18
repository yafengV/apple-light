import AppKit
import Foundation

extension WorkspaceStore {
  func openDeepLink(_ link: ShipiOSDeepLink) async {
    switch link {
    case .workspace: returnToWorkspace()
    case .projects: showProjects()
    case .plugins: showPlugins()
    case .automations: showAutomations()
    case .settings(let page): openSettings(page)
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

  func copyTaskDeepLink(_ task: WorkspaceTask) {
    guard let value = ShipiOSDeepLink.task(task.id).url?.absoluteString else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
