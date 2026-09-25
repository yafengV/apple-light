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
  var panelSizes = WorkspacePanelSizes()
  var showingFiles = false
  var showingReview = false
  var showingTerminal = false
  private(set) var terminals: [TerminalSession] = []
  private(set) var selectedTerminalID: UUID?
  var terminal: TerminalSession? { terminals.first { $0.id == selectedTerminalID } }
  var terminalFocus: TerminalFocusRequest?

  init(taskID: String) { self.taskID = taskID }

  func resizeInspector(to width: Double) {
    guard width.isFinite, width >= 0 else { return }
    panelSizes.inspectorWidth = width
  }
  func resizeTerminal(to height: Double) {
    guard height.isFinite, height >= 0 else { return }
    panelSizes.terminalHeight = height
  }
  func resetInspectorSize() { panelSizes.inspectorWidth = nil }
  func resetTerminalSize() { panelSizes.terminalHeight = nil }

  func configure(project: String) {
    let root = project.isEmpty ? nil : GitBranchService.canonicalRoot(URL(fileURLWithPath: project))
    guard root != workspace.root else { return }
    terminals.forEach { $0.stop() }
    terminals = []
    selectedTerminalID = nil
    terminalFocus = nil
    showingFiles = false
    showingReview = false
    showingTerminal = false
    workspace.setProject(root)
  }

  func toggleTerminal() {
    guard workspace.root != nil else { return }
    if terminal == nil { _ = newTerminal() }
    showingTerminal.toggle()
    if showingTerminal { focusTerminal() } else { terminalFocus = nil }
  }

  func focusTerminal() {
    guard showingTerminal, let terminal else { return }
    terminalFocus = TerminalFocusRequest(
      scope: TerminalScope(root: terminal.root, conversation: taskID), sessionID: terminal.id)
  }

  @discardableResult func newTerminal(id: UUID = UUID()) -> TerminalSession? {
    if let existing = terminals.first(where: { $0.id == id }) { return existing }
    guard let root = workspace.root else { return nil }
    let session = TerminalSession(root: root, id: id)
    terminals.append(session)
    selectedTerminalID = session.id
    return session
  }

  func selectTerminal(_ id: UUID, focus: Bool = true) {
    guard terminals.contains(where: { $0.id == id }) else { return }
    selectedTerminalID = id
    showingTerminal = true
    if focus { focusTerminal() }
  }

  func closeTerminal(_ id: UUID) {
    guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
    terminals.remove(at: index).stop()
    if selectedTerminalID == id {
      selectedTerminalID = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)].id
      terminalFocus = nil
    }
  }

  @discardableResult func restartTerminal(_ id: UUID) -> TerminalSession? {
    guard let index = terminals.firstIndex(where: { $0.id == id }), let root = workspace.root else { return nil }
    terminals[index].stop()
    let replacement = TerminalSession(root: root)
    terminals[index] = replacement
    selectTerminal(replacement.id)
    return replacement
  }

  func restartTerminal() {
    if let id = terminal?.id { _ = restartTerminal(id) }
    else if let terminal = newTerminal() { selectTerminal(terminal.id) }
  }

  func hideTerminal() { showingTerminal = false; terminalFocus = nil }

  func shutdown() {
    terminals.forEach { $0.stop() }
    terminals = []
    selectedTerminalID = nil
    terminalFocus = nil
    showingFiles = false
    showingReview = false
    showingTerminal = false
    workspace.setProject(nil)
  }
}
