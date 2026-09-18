import Foundation
import Observation

/// A task's content layout is local to the window, while the underlying views stay alive.
@MainActor @Observable final class TaskWindowTabs {
  let taskID: String
  let browser: TaskWindowBrowser
  let panels: TaskWindowPanels
  @ObservationIgnored var onTabWillClose: ((WorkspaceContentTab) -> Void)?
  @ObservationIgnored var onTabReplaced: ((String, String) -> Void)?
  private(set) var tabs: [WorkspaceContentTab] = []
  private var placements: [String: WorkspaceTabPlacement] = [:]
  private var selections: [WorkspaceTabPlacement: String] = [:]
  private(set) var focusedID: String?
  private var lastContentID: String?
  var lastContentForCommand: String? { lastContentID }
  var showingRight = false
  var showingBottom = false
  var showingTabs = true
  var primarySide = WorkspacePaneSide.left
  var chatFocus = UUID()
  private struct Closed { let tab: WorkspaceContentTab; let placement: WorkspaceTabPlacement }
  private var closed: [Closed] = []
  @ObservationIgnored private var openingPlacement = WorkspaceTabPlacement.left
  @ObservationIgnored private var synchronizingBrowser = false
  private let dragScope = UUID().uuidString

  func dragToken(_ id: String) -> String { "shipios-task-window-tab:\(dragScope):\(id)" }
  func draggedTab(_ value: String) -> String? {
    let prefix = "shipios-task-window-tab:\(dragScope):"
    guard value.hasPrefix(prefix) else { return nil }
    let id = String(value.dropFirst(prefix.count))
    return tabs.contains(where: { $0.id == id }) ? id : nil
  }

  init(taskID: String, browser: TaskWindowBrowser, panels: TaskWindowPanels) {
    self.taskID = taskID; self.browser = browser; self.panels = panels
    browser.session.selectsAdjacentTabOnClose = false
    browser.session.onTabOpened = { [weak self] id in
      guard let self else { return }
      let tab = WorkspaceContentTab.browser(id, owner: taskID)
      tabs.append(tab); placements[tab.id] = openingPlacement
    }
    browser.session.onTabSelected = { [weak self] id in
      guard let self, !synchronizingBrowser else { return }
      activate(WorkspaceContentTab.browser(id, owner: taskID).id, focus: false)
    }
    browser.session.onTabClosed = { [weak self] id in
      self?.remove(WorkspaceContentTab.browser(id, owner: taskID).id)
    }
  }

  func placement(_ id: String) -> WorkspaceTabPlacement { placements[id] ?? .left }
  func visibleTabs(_ placement: WorkspaceTabPlacement) -> [WorkspaceContentTab] {
    tabs.filter { self.placement($0.id) == placement }
  }
  func selected(_ placement: WorkspaceTabPlacement) -> WorkspaceContentTab? {
    visibleTabs(placement).first { $0.id == selections[placement] }
  }
  var focused: WorkspaceContentTab? { tabs.first { $0.id == focusedID } }
  var chatVisible: Bool { selected(.left) == nil }
  var canReopen: Bool { !closed.isEmpty }
  func isVisible(_ id: String) -> Bool {
    let place = placement(id)
    return selections[place] == id && (place == .left || (place == .right && showingRight && !panels.showingFiles)
      || (place == .bottom && showingBottom))
  }
  func title(_ tab: WorkspaceContentTab) -> String {
    switch tab {
    case .browser(let id, _): browser.session.tabs.first { $0.id == id }?.title ?? "浏览器"
    case .review: "审查"
    case .terminal(let id, _): panels.terminals.first { $0.id == id }?.title ?? "终端"
    }
  }

  func activate(_ id: String?, focus: Bool = true) {
    guard let id else {
      selections[.left] = nil; focusedID = nil
      if focus { chatFocus = UUID() }
      return
    }
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    let place = placement(id)
    selections[place] = id
    if place == .right { panels.showingFiles = false; showingRight = true }
    if place == .bottom { showingBottom = true }
    focusedID = id; lastContentID = id
    if let browserID = tab.browserID {
      synchronizingBrowser = true
      browser.session.select(browserID, focus: focus)
      synchronizingBrowser = false
    } else if let terminalID = tab.terminalID {
      panels.selectTerminal(terminalID, focus: focus)
    }
  }

  func newBrowser(in place: WorkspaceTabPlacement = .left) {
    guard place == .left || place == .right else { return }
    openingPlacement = place
    browser.newTab()
    openingPlacement = .left
  }
  func openBrowser(_ url: URL, presentation: MessageWebLinkPresentation) {
    guard BrowserAddress.permits(url) else { return }
    openingPlacement = presentation == .fullWidth ? .left : .right
    defer { openingPlacement = .left }
    if presentation == .backgroundTab {
      let tab = browser.session.newTab(activate: false)
      let id = WorkspaceContentTab.browser(tab.id, owner: taskID).id
      if selected(.right) == nil { selections[.right] = id }
      showingRight = true; panels.showingFiles = false
      tab.address = url.absoluteString; tab.navigate()
      return
    }
    browser.open(url, presentation: presentation)
    if let id = browser.session.selection {
      move(WorkspaceContentTab.browser(id, owner: taskID).id, to: openingPlacement)
    }
    if presentation == .fullWidth { showingRight = false }
  }
  func openReview(in place: WorkspaceTabPlacement = .left, defaultScope: GitReviewScope) {
    guard panels.workspace.root != nil, place != .bottom else { return }
    let tab = WorkspaceContentTab.review(owner: taskID)
    if !tabs.contains(tab) { tabs.append(tab); panels.workspace.reviewScope = defaultScope }
    move(tab.id, to: place)
    Task { await panels.workspace.refreshGit() }
  }
  func newTerminal(in place: WorkspaceTabPlacement = .bottom) {
    guard place != .detached, let terminal = panels.newTerminal() else { return }
    let tab = WorkspaceContentTab.terminal(terminal.id, owner: taskID)
    tabs.append(tab); placements[tab.id] = place; activate(tab.id)
  }
  func restartTerminal(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.terminalID == id }),
      let replacement = panels.restartTerminal(id) else { return }
    let old = tabs[index], place = placement(old.id)
    let tab = WorkspaceContentTab.terminal(replacement.id, owner: taskID)
    clearSelection(old.id); placements[old.id] = nil
    tabs[index] = tab; placements[tab.id] = place; activate(tab.id)
    onTabReplaced?(old.id, tab.id)
  }
  func toggleTerminal(in place: WorkspaceTabPlacement) {
    let visible = place == .right ? showingRight : showingBottom
    if visible, selected(place)?.terminalID != nil { hide(place); return }
    if let existing = visibleTabs(place).first(where: { $0.terminalID != nil }) { activate(existing.id) }
    else { newTerminal(in: place) }
  }
  func toggleBottom() {
    if showingBottom { hide(.bottom) }
    else if let tab = selected(.bottom) ?? visibleTabs(.bottom).first { activate(tab.id) }
    else { newTerminal() }
  }
  func hide(_ place: WorkspaceTabPlacement) {
    if place == .right { showingRight = false; panels.showingFiles = false }
    if place == .bottom { showingBottom = false }
    if focusedID.map(placement) == place { activate(selected(.left)?.id) }
  }
  func canMove(_ id: String, to place: WorkspaceTabPlacement) -> Bool {
    guard let tab = tabs.first(where: { $0.id == id }), place != .detached else { return false }
    return place != .bottom || tab.terminalID != nil
  }
  func move(_ id: String, to place: WorkspaceTabPlacement) {
    guard canMove(id, to: place) else { return }
    let previous = placement(id)
    if previous != place {
      clearSelection(id); placements[id] = place
      repairSelection(previous)
    }
    activate(id)
  }
  func toggleFullWidth() {
    guard let id = focusedID ?? lastContentID, tabs.contains(where: { $0.id == id }) else { return }
    move(id, to: placement(id) == .left ? .right : .left)
  }
  func close(_ id: String) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    onTabWillClose?(tab)
    if let browserID = tab.browserID { browser.session.close(browserID) }
    else {
      if let terminalID = tab.terminalID { panels.closeTerminal(terminalID) }
      remove(id)
    }
  }
  private func remove(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let place = placement(id), wasFocused = focusedID == id
    closed.append(Closed(tab: tabs[index], placement: place))
    if closed.count > 20 { closed.removeFirst(closed.count - 20) }
    tabs.remove(at: index); placements[id] = nil; clearSelection(id)
    repairSelection(place)
    if wasFocused {
      if let next = selected(place) { activate(next.id) }
      else { chatFocus = UUID() }
    }
  }
  private func clearSelection(_ id: String) {
    for place in [WorkspaceTabPlacement.left, .right, .bottom] where selections[place] == id {
      selections[place] = nil
    }
    if focusedID == id { focusedID = nil }
    if lastContentID == id { lastContentID = nil }
  }
  private func repairSelection(_ place: WorkspaceTabPlacement) {
    // The main pane always has its chat tab; side panes fall back to a surviving tab.
    if place != .left, selected(place) == nil { selections[place] = visibleTabs(place).first?.id }
    if visibleTabs(place).isEmpty {
      if place == .right { showingRight = false }
      if place == .bottom { showingBottom = false }
    }
  }
  func closeOthers(keeping id: String?, in place: WorkspaceTabPlacement) {
    for tab in visibleTabs(place).reversed() where tab.id != id { close(tab.id) }
    activate(id)
  }
  func canCloseRight(of id: String?, in place: WorkspaceTabPlacement) -> Bool {
    let ids: [String?] = (place == .left ? [nil] : []) + visibleTabs(place).map { Optional($0.id) }
    guard let index = ids.firstIndex(of: id) else { return false }
    return index + 1 < ids.count
  }
  func closeRight(of id: String?, in place: WorkspaceTabPlacement) {
    let ids: [String?] = (place == .left ? [nil] : []) + visibleTabs(place).map { Optional($0.id) }
    guard let index = ids.firstIndex(of: id) else { return }
    for candidate in ids.dropFirst(index + 1).reversed() { if let candidate { close(candidate) } }
    activate(id)
  }
  func reopen() {
    guard let state = closed.popLast() else { return }
    switch state.tab {
    case .browser:
      openingPlacement = state.placement
      browser.reopen()
      openingPlacement = .left
    case .review: openReview(in: state.placement, defaultScope: panels.workspace.reviewScope)
    case .terminal: newTerminal(in: state.placement)
    }
  }
  @discardableResult func reorder(_ source: String, relativeTo target: String, after: Bool) -> Bool {
    guard source != target, placement(source) == placement(target),
      let index = tabs.firstIndex(where: { $0.id == source }), tabs.contains(where: { $0.id == target }) else { return false }
    let tab = tabs.remove(at: index)
    let destination = tabs.firstIndex(where: { $0.id == target })!
    tabs.insert(tab, at: destination + (after ? 1 : 0)); return true
  }
  func focusSlot(_ oneBased: Int) {
    let ids: [String?] = [nil] + tabs.map { Optional($0.id) }
    guard oneBased > 0, oneBased <= ids.count else { return }
    activate(ids[oneBased - 1])
  }
  func cycle(_ offset: Int) {
    let ids: [String?] = [nil] + tabs.map { Optional($0.id) }
    guard ids.count > 1 else { return }
    let index = ids.firstIndex(of: focusedID) ?? 0
    activate(ids[(index + offset + ids.count) % ids.count])
  }
  func revealChat() {
    if let tab = selected(.left) { move(tab.id, to: .right) }
    activate(nil)
  }
  func resetProjectTabs() {
    for tab in tabs where tab.browserID == nil { clearSelection(tab.id); placements[tab.id] = nil }
    tabs.removeAll { $0.browserID == nil }
    closed.removeAll { $0.tab.browserID == nil }
    repairSelection(.right); repairSelection(.bottom)
  }
}
