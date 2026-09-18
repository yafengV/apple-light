import Observation

@MainActor @Observable final class TaskWindowResources {
  let browsers = TaskWindowBrowsers()
  let panels = TaskWindowPanelSessions()
  private(set) var tasks: [String: TaskWindowTabs] = [:]

  func prepare(_ taskID: String, store: WorkspaceStore) {
    let project = store.library.tasks.first { $0.id == taskID }?.project ?? ""
    let oldRoot = panels.tasks[taskID]?.workspace.root
    let panel = panels.panels(for: taskID, project: project)
    store.additionalTaskWindowPanels.add(panels)
    if let existing = tasks[taskID] {
      if oldRoot != panel.workspace.root { existing.resetProjectTabs() }
    } else {
      tasks[taskID] = TaskWindowTabs(taskID: taskID,
        browser: browsers.browser(for: taskID, store: store), panels: panel)
    }
  }
  func retainTasks(_ available: Set<String>, displaying: String?) {
    panels.retainTasks(available, displaying: displaying)
    for id in Array(tasks.keys) where !available.contains(id) {
      tasks[id]?.resetProjectTabs()
      if id != displaying { tasks[id] = nil }
    }
  }
  func shutdown() { browsers.shutdown(); panels.shutdown(); tasks.removeAll() }
}
