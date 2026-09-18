import Foundation

enum ContentTabLauncherAction {
  case browser, review, terminal, reopen, files, plugins, plugin(String), automations, terminalOptions
}

extension WorkspaceStore {
  /// Returns true only when an independent window should reveal a page in the main window.
  @discardableResult func performContentTabLauncherAction(_ action: ContentTabLauncherAction,
    in placement: WorkspaceTabPlacement, taskTabs: TaskWindowTabs? = nil,
    openFiles: () -> Void) -> Bool {
    let hasProject = taskTabs.map { $0.panels.workspace.root != nil } ?? (project != nil)
    switch action {
    case .browser:
      guard placement != .bottom else { return false }
      if let taskTabs { taskTabs.newBrowser(in: placement) }
      else { newBrowserTab(in: placement) }
    case .review:
      guard hasProject, placement != .bottom else { return false }
      if let taskTabs { taskTabs.openReview(in: placement, defaultScope: library.gitPreferences.defaultReviewScope) }
      else { openReviewTab(in: placement) }
    case .terminal:
      guard hasProject else { return false }
      if let taskTabs { taskTabs.newTerminal(in: .bottom) }
      else { newTerminalTab(in: .bottom) }
    case .reopen:
      if let taskTabs { taskTabs.reopen() }
      else { reopenClosedWorkspaceTab() }
    case .files:
      guard hasProject else { return false }
      openFiles()
    case .plugin(let id):
      // The menu can remain open while a plugin is disabled or removed elsewhere.
      guard pluginPreferences.installed.contains(where: { $0.id == id && $0.enabled }) else { return false }
      showPlugins()
      openPluginDetail(id)
      return taskTabs != nil
    case .plugins:
      showPlugins()
      return taskTabs != nil
    case .automations:
      showAutomations()
      return taskTabs != nil
    case .terminalOptions:
      openSettings(.runtime)
      return taskTabs != nil
    }
    return false
  }
}
