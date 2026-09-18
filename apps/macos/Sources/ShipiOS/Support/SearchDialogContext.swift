import Foundation

/// An alternate window supplies routes without changing the main workspace selection.
@MainActor struct SearchDialogContext {
  let currentTaskID: String
  let commandEnabled: (String) -> Bool
  let performCommand: (String) -> Void
  let canSelectTask: (WorkspaceTask) -> Bool
  let navigate: (WorkspaceTask) -> Void
  let cancel: () -> Void
  var browserResults: [CommandBrowserResult] = []
  var canOpenBrowser: (CommandBrowserResult) -> Bool = { _ in false }
  var openBrowser: (CommandBrowserResult) -> Void = { _ in }

  func selectBrowser(_ result: CommandBrowserResult) {
    guard canOpenBrowser(result) else { return }
    openBrowser(result)
  }

  func execute(_ id: String) {
    guard commandEnabled(id) else { return }
    performCommand(id)
  }

  func select(_ task: WorkspaceTask) {
    guard canSelectTask(task) else { return }
    navigate(task)
  }
}

enum TaskWindowSearchMode { case commands, tasks, files }
