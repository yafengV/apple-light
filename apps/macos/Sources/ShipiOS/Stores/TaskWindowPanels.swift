import Foundation
import Observation

/// One window owns these resources until it closes, including tasks currently off screen.
@MainActor @Observable final class TaskWindowPanelSessions {
  private(set) var tasks: [String: TaskWindowPanels] = [:]

  func panels(for taskID: String, project: String) -> TaskWindowPanels {
    let panels = tasks[taskID] ?? TaskWindowPanels(taskID: taskID)
    panels.configure(project: project)
    tasks[taskID] = panels
    return panels
  }

  func retainTasks(_ available: Set<String>, displaying: String? = nil) {
    for id in Array(tasks.keys) where !available.contains(id) {
      tasks[id]?.shutdown()
      // Keep the mounted model long enough to render the task-unavailable page.
      if id != displaying { tasks[id] = nil }
    }
  }

  func shutdown() {
    tasks.values.forEach { $0.shutdown() }
    tasks.removeAll()
  }
}

@MainActor @Observable final class TaskWindowPanels {
  let taskID: String
  let workspace = DeveloperWorkspace()
  var showingFiles = false
  var showingReview = false
  var showingTerminal = false
  private(set) var terminal: TerminalSession?
  var terminalFocus: TerminalFocusRequest?

  init(taskID: String) { self.taskID = taskID }

  func configure(project: String) {
    let root = project.isEmpty ? nil : GitBranchService.canonicalRoot(URL(fileURLWithPath: project))
    guard root != workspace.root else { return }
    terminal?.stop()
    terminal = nil
    terminalFocus = nil
    showingFiles = false
    showingReview = false
    showingTerminal = false
    workspace.setProject(root)
  }

  func toggleTerminal() {
    guard let root = workspace.root else { return }
    if terminal == nil { terminal = TerminalSession(root: root) }
    showingTerminal.toggle()
    if showingTerminal { focusTerminal() } else { terminalFocus = nil }
  }

  func focusTerminal() {
    guard showingTerminal, let terminal else { return }
    terminalFocus = TerminalFocusRequest(
      scope: TerminalScope(root: terminal.root, conversation: taskID), sessionID: terminal.id)
  }

  func restartTerminal() {
    guard let root = workspace.root else { return }
    terminal?.stop()
    terminal = TerminalSession(root: root)
    showingTerminal = true
    focusTerminal()
  }

  func hideTerminal() { showingTerminal = false; terminalFocus = nil }

  func shutdown() {
    terminal?.stop()
    terminal = nil
    terminalFocus = nil
    showingFiles = false
    showingReview = false
    showingTerminal = false
    workspace.setProject(nil)
  }
}
