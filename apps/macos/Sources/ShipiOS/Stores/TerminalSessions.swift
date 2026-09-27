import Foundation
import Observation

/// Sessions survive hidden panels and navigation, but are not shared between conversations.
@MainActor @Observable
final class TerminalSessions {
  private var sessions: [TerminalScope: [UUID: TerminalSession]] = [:]
  private var splitSessions: [TerminalScope: [UUID: TerminalSession]] = [:]
  private var splitFractions: [TerminalScope: [UUID: Double]] = [:]
  func session(for scope: TerminalScope) -> TerminalSession {
    if let session = sessions[scope]?.values.first { return session }
    return newSession(for: scope)
  }
  func newSession(for scope: TerminalScope, id: UUID = UUID()) -> TerminalSession {
    if let existing = sessions[scope]?[id] { return existing }
    let session = TerminalSession(root: scope.root, id: id)
    sessions[scope, default: [:]][session.id] = session
    return session
  }
  func session(_ id: UUID, for scope: TerminalScope) -> TerminalSession? {
    sessions[scope]?[id]
  }
  func splitSession(for id: UUID, in scope: TerminalScope) -> TerminalSession? {
    splitSessions[scope]?[id]
  }
  func splitFraction(for id: UUID, in scope: TerminalScope) -> Double {
    splitFractions[scope]?[id] ?? 0.5
  }
  func setSplitFraction(_ fraction: Double, for id: UUID, in scope: TerminalScope) {
    guard fraction.isFinite, splitSessions[scope]?[id] != nil else { return }
    splitFractions[scope, default: [:]][id] = min(0.8, max(0.2, fraction))
  }
  @discardableResult func split(_ id: UUID, in scope: TerminalScope) -> TerminalSession? {
    guard sessions[scope]?[id] != nil else { return nil }
    if let existing = splitSessions[scope]?[id] { return existing }
    let session = TerminalSession(root: scope.root)
    splitSessions[scope, default: [:]][id] = session
    return session
  }
  func closeSplit(_ id: UUID, in scope: TerminalScope) {
    splitSessions[scope]?.removeValue(forKey: id)?.stop()
    if splitSessions[scope]?.isEmpty == true { splitSessions[scope] = nil }
    splitFractions[scope]?[id] = nil
    if splitFractions[scope]?.isEmpty == true { splitFractions[scope] = nil }
  }
  @discardableResult func restartSplit(_ id: UUID, in scope: TerminalScope) -> TerminalSession? {
    guard splitSessions[scope]?[id] != nil else { return nil }
    let fraction = splitFraction(for: id, in: scope)
    closeSplit(id, in: scope)
    let session = split(id, in: scope)
    setSplitFraction(fraction, for: id, in: scope)
    return session
  }
  func primaryID(containing id: UUID, in scope: TerminalScope) -> UUID? {
    if sessions[scope]?[id] != nil { return id }
    return splitSessions[scope]?.first(where: { $0.value.id == id })?.key
  }
  func scope(containing id: UUID) -> TerminalScope? {
    sessions.first { $0.value[id] != nil }?.key
  }
  @discardableResult func move(
    _ id: UUID, from source: TerminalScope, to destination: TerminalScope
  ) -> Bool {
    guard source != destination, let session = sessions[source]?.removeValue(forKey: id) else {
      return source == destination && sessions[source]?[id] != nil
    }
    if sessions[source]?.isEmpty == true { sessions[source] = nil }
    sessions[destination, default: [:]][id] = session
    if let split = splitSessions[source]?.removeValue(forKey: id) {
      if splitSessions[source]?.isEmpty == true { splitSessions[source] = nil }
      splitSessions[destination, default: [:]][id] = split
    }
    if let fraction = splitFractions[source]?.removeValue(forKey: id) {
      if splitFractions[source]?.isEmpty == true { splitFractions[source] = nil }
      splitFractions[destination, default: [:]][id] = fraction
    }
    return true
  }
  func adopt(from source: TerminalScope, to destination: TerminalScope) {
    guard source.project == destination.project, source != destination,
      sessions[destination] == nil, let sourceSessions = sessions.removeValue(forKey: source)
    else { return }
    sessions[destination] = sourceSessions
    if let sourceSplits = splitSessions.removeValue(forKey: source) {
      splitSessions[destination] = sourceSplits
    }
    if let fractions = splitFractions.removeValue(forKey: source) {
      splitFractions[destination] = fractions
    }
  }
  func restart(_ scope: TerminalScope) -> TerminalSession {
    close(scope)
    return session(for: scope)
  }
  func restart(_ id: UUID, for scope: TerminalScope) -> TerminalSession {
    sessions[scope]?.removeValue(forKey: id)?.stop()
    // The tab and any detached window keep their identity; only the shell changes.
    return newSession(for: scope, id: id)
  }
  func close(_ id: UUID, for scope: TerminalScope) {
    closeSplit(id, in: scope)
    sessions[scope]?.removeValue(forKey: id)?.stop()
    if sessions[scope]?.isEmpty == true { sessions[scope] = nil }
  }
  func close(_ scope: TerminalScope) {
    splitFractions[scope] = nil
    for split in splitSessions.removeValue(forKey: scope)?.values ?? [:].values { split.stop() }
    for session in sessions.removeValue(forKey: scope)?.values ?? [:].values { session.stop() }
  }
  func shutdown() {
    splitFractions.removeAll()
    for split in splitSessions.values.flatMap(\.values) { split.stop() }
    splitSessions.removeAll()
    for session in sessions.values.flatMap(\.values) { session.stop() }
    sessions.removeAll()
  }
}

extension WorkspaceStore {
  var availableEnvironmentActions: [EnvironmentAction] {
    guard let project else { return [] }
    return (library.profiles[project.path]?.actions ?? []).filter(\.isRunnableOnMac)
  }

  func runEnvironmentAction(_ action: EnvironmentAction) {
    guard let project, destination == .workspace, !shuttingDown,
      library.profiles[project.path]?.actions.contains(action) == true,
      action.isRunnableOnMac else { return }
    newTerminalTab(in: library.defaultTerminalLocation)
    guard let id = focusedWorkspaceContentTab?.terminalID,
      let session = terminalSession(id), session.run(action) else {
      error = "无法在终端启动操作：\(action.title)"
      return
    }
    error = nil
  }

  func newTerminalTab(in placement: WorkspaceTabPlacement = .bottom) {
    guard let scope = terminalScope else { return }
    destination = .workspace
    let session = workspace.terminals.newSession(for: scope)
    let tab = WorkspaceContentTab.terminal(session.id, owner: currentWorkspaceTabOwner)
    workspaceTabs.append(tab)
    workspaceTabPlacements[tab.id] = placement
    activateWorkspaceTab(tab.id)
  }

  func toggleTerminalPanel() {
    guard project != nil else { return }
    destination = .workspace
    if library.defaultTerminalLocation == .right {
      if showingInspector, activeRightWorkspaceContentTab?.terminalID != nil {
        showingInspector = false
        terminalFocusRequest = nil
        focusComposer = UUID()
      } else if let tab = visibleWorkspaceContentTabs(in: .right).first(where: {
        $0.terminalID != nil
      }) {
        showingInspector = true
        activateWorkspaceTab(tab.id)
      } else {
        newTerminalTab(in: .right)
      }
    } else if showingTerminal, activeBottomWorkspaceContentTab?.terminalID != nil {
      hideTerminalPanel()
    } else if let tab = visibleWorkspaceContentTabs(in: .bottom).first(where: {
      $0.terminalID != nil
    }) {
      showingTerminal = true
      activateWorkspaceTab(tab.id)
    } else {
      newTerminalTab(in: .bottom)
    }
  }
  func toggleBottomPanel() {
    guard project != nil else { return }
    destination = .workspace
    if showingTerminal { hideTerminalPanel() }
    else {
      if visibleWorkspaceContentTabs(in: .bottom).isEmpty { newTerminalTab(in: .bottom) }
      showingTerminal = true
      if let tab = activeBottomWorkspaceContentTab
        ?? visibleWorkspaceContentTabs(in: .bottom).first {
        activateWorkspaceTab(tab.id)
      }
    }
  }
  func hideTerminalPanel() {
    showingTerminal = false
    terminalFocusRequest = nil
    focusComposer = UUID()
  }
  func focusTerminal(_ requestedSessionID: UUID? = nil) {
    let sessionID = requestedSessionID
      ?? focusedWorkspaceContentTab?.terminalID
      ?? activeBottomWorkspaceContentTab?.terminalID
    guard destination == .workspace, let sessionID,
      let tab = visibleWorkspaceContentTabs.first(where: { tab in
        guard let primaryID = tab.terminalID, let scope = terminalScope(for: tab) else { return false }
        return workspace.terminals.primaryID(containing: sessionID, in: scope) == primaryID
      }),
      let scope = terminalScope(for: tab) else { return }
    terminalFocusRequest = TerminalFocusRequest(scope: scope, sessionID: sessionID)
  }
  func canFocusTerminal(_ request: TerminalFocusRequest) -> Bool {
    guard destination == .workspace, presentedOverlay == nil,
      !showingModelPicker, !showingBranchPicker,
      terminalFocusRequest == request,
      let sessionID = request.sessionID,
      let tab = visibleWorkspaceContentTabs.first(where: { tab in
        guard let primaryID = tab.terminalID, let scope = terminalScope(for: tab) else { return false }
        return workspace.terminals.primaryID(containing: sessionID, in: scope) == primaryID
      }),
      terminalScope(for: tab) == request.scope else { return false }
    switch workspaceTabPlacement(tab.id) {
    case .left: return activeWorkspaceTabID == tab.id
    case .right: return showingInspector && activeRightWorkspaceTabID == tab.id
    case .bottom: return showingTerminal && activeBottomWorkspaceTabID == tab.id
    case .detached: return focusedWorkspaceTabID == tab.id
    }
  }
  var terminalScope: TerminalScope? {
    project.map { TerminalScope(root: $0, conversation: draftKey) }
  }
  func terminalScope(for tab: WorkspaceContentTab) -> TerminalScope? {
    if let id = tab.terminalID, let scope = workspace.terminals.scope(containing: id) {
      return scope
    }
    let path: String?
    if tab.owner.hasPrefix("new:") { path = String(tab.owner.dropFirst(4)) }
    else { path = library.tasks.first(where: { $0.id == tab.owner })?.project }
    guard let path, !path.isEmpty else { return nil }
    return TerminalScope(root: URL(fileURLWithPath: path), conversation: tab.owner)
  }
  func terminalSession(_ id: UUID) -> TerminalSession? {
    guard let tab = workspaceTabs.first(where: { $0.terminalID == id }),
      let scope = terminalScope(for: tab) else { return nil }
    return workspace.terminals.session(id, for: scope)
  }
  @discardableResult func restartTerminalTab(_ id: UUID) -> TerminalSession? {
    guard !shuttingDown, let tab = workspaceTabs.first(where: { $0.terminalID == id }),
      let scope = terminalScope(for: tab) else { return nil }
    return workspace.terminals.restart(id, for: scope)
  }
  @discardableResult func splitTerminalTab(_ id: UUID) -> TerminalSession? {
    guard !shuttingDown, let tab = workspaceTabs.first(where: { $0.terminalID == id }),
      let scope = terminalScope(for: tab),
      let split = workspace.terminals.split(id, in: scope) else { return nil }
    focusTerminal(split.id)
    return split
  }
  func closeTerminalSplit(_ id: UUID) {
    guard let tab = workspaceTabs.first(where: { $0.terminalID == id }),
      let scope = terminalScope(for: tab) else { return }
    let splitID = workspace.terminals.splitSession(for: id, in: scope)?.id
    workspace.terminals.closeSplit(id, in: scope)
    if terminalFocusRequest?.sessionID == splitID { focusTerminal(id) }
  }
  @discardableResult func restartTerminalSplit(_ id: UUID) -> TerminalSession? {
    guard let tab = workspaceTabs.first(where: { $0.terminalID == id }),
      let scope = terminalScope(for: tab) else { return nil }
    let split = workspace.terminals.restartSplit(id, in: scope)
    if let split { focusTerminal(split.id) }
    return split
  }
  func adoptDraftTerminal(_ source: TerminalScope?, run: AgentRun) {
    guard let source, let task = library.task(containing: run.id), !run.project.isEmpty else { return }
    workspace.terminals.adopt(from: source,
      to: TerminalScope(root: URL(fileURLWithPath: run.project), conversation: task.id))
  }
}
