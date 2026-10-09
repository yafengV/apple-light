import Foundation
import Observation
import WebKit

/// A task's content layout is local to the window, while the underlying views stay alive.
@MainActor @Observable final class TaskWindowTabs {
  let taskID: String
  let browser: TaskWindowBrowser
  let panels: TaskWindowPanels
  let pullRequestPresentations = PullRequestTabPresentations()
  @ObservationIgnored var pullRequest: ((String) -> GitHubPullRequest?)?
  @ObservationIgnored var watchAutomation: ((UUID, String) -> ShipAutomation?)?
  @ObservationIgnored var onTabWillClose: ((WorkspaceContentTab) -> Void)?
  @ObservationIgnored var isTabPinned: ((String) -> Bool)?
  @ObservationIgnored var canCloseFileTab: ((WorkspaceContentTab) -> Bool)?
  @ObservationIgnored var onTabReplaced: ((String, String) -> Void)?
  @ObservationIgnored var backgroundTerminalTitle: ((UUID) -> String?)?
  @ObservationIgnored var planDocument: ((String) -> CodexPlanDocument?)?
  private(set) var tabs: [WorkspaceContentTab] = []
  private var placements: [String: WorkspaceTabPlacement] = [:]
  private var selections: [WorkspaceTabPlacement: String] = [:]
  private(set) var focusedID: String?
  private var lastContentID: String?
  var lastContentForCommand: String? { lastContentID }
  var showingRight = false
  var showingBottom = false
  var showingTabs = true
  var contentLayoutMode: WorkspaceContentLayoutMode?
  var contentRightToLeft = false
  var effectiveContentLayoutMode: WorkspaceContentLayoutMode {
    contentLayoutMode ?? (visibleTabs(.left).contains { $0.id == selections[.left] } ? .full : .split)
  }
  var claimsAdjacentContentTabs: Bool {
    commandContentTab != nil || (effectiveContentLayoutMode == .full && tabs.contains {
      [.left, .right].contains(placement($0.id))
    })
  }
  var primarySide = WorkspacePaneSide.left
  var chatFocus = UUID()
  private struct Closed { let tab: WorkspaceContentTab; let placement: WorkspaceTabPlacement }
  private var closed: [Closed] = []
  @ObservationIgnored private var openingPlacement = WorkspaceTabPlacement.left
  @ObservationIgnored private var synchronizingBrowser = false
  @ObservationIgnored private var closeControllers: [ContentTabClosePanel: ContentTabCloseController] = [:]
  private let dragScope = UUID().uuidString
  private(set) var draggingTabID: String?
  private(set) var dragSessionID: UUID?
  private(set) var dropPlacement: WorkspaceTabPlacement?

  func beginDrag(_ id: String) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    draggingTabID = id
    dragSessionID = UUID()
    dropPlacement = nil
  }
  func endDrag(session: UUID? = nil) {
    if let session, session != dragSessionID { return }
    draggingTabID = nil
    dragSessionID = nil
    dropPlacement = nil
  }
  func canDropDraggedTab(to place: WorkspaceTabPlacement) -> Bool {
    draggingTabID.map { canMove($0, to: place) } ?? false
  }
  func targetDrop(_ place: WorkspaceTabPlacement, entered: Bool) {
    if entered, canDropDraggedTab(to: place) { dropPlacement = place }
    else if dropPlacement == place { dropPlacement = nil }
  }
  @discardableResult func drop(_ values: [String], to place: WorkspaceTabPlacement) -> Bool {
    defer { endDrag() }
    guard let id = values.compactMap(draggedTab).first, canMove(id, to: place) else { return false }
    move(id, to: place)
    return true
  }

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
    browser.session.createChildTab = { [weak self] source, configuration in
      self?.newBrowserChild(from: source, configuration: configuration)
    }
    browser.session.onTabOpened = { [weak self] id in
      guard let self else { return }
      let tab = WorkspaceContentTab.browser(id, owner: taskID)
      tabs.append(tab); placements[tab.id] = openingPlacement
    }
    browser.session.onTabSelected = { [weak self] id in
      guard let self, !synchronizingBrowser else { return }
      activate(WorkspaceContentTab.browser(id, owner: taskID).id, focus: false)
    }
    browser.session.onTabClosed = { [weak self] id, reason in
      self?.remove(WorkspaceContentTab.browser(id, owner: taskID).id, recordCloseUndo: reason.recordsUndo)
    }
    browser.session.onTabMoved = { [weak self] id in
      guard let self else { return }
      let key = WorkspaceContentTab.browser(id, owner: taskID).id
      closeControllers[ContentTabClosePanel(placement(key), id: key), default: .init()].history.moved(key)
    }
    browser.session.onTabsReordered = { [weak self] ids in
      guard let self else { return }
      var ordered = ids.compactMap { id in self.tabs.first { $0.browserID == id } }.makeIterator()
      for index in tabs.indices where tabs[index].browserID != nil {
        if let tab = ordered.next() { tabs[index] = tab }
      }
    }
  }

  func placement(_ id: String) -> WorkspaceTabPlacement { placements[id] ?? .left }
  func visibleTabs(_ placement: WorkspaceTabPlacement) -> [WorkspaceContentTab] {
    tabs.filter { self.placement($0.id) == placement }
  }
  var primaryContentTabs: [WorkspaceContentTab] {
    tabs.filter { [.left, .right].contains(placement($0.id)) }
  }
  func presentedTabs(_ place: WorkspaceTabPlacement) -> [WorkspaceContentTab] {
    if place == .left || place == .right {
      let surface: WorkspaceTabPlacement = effectiveContentLayoutMode == .full ? .left : .right
      return place == surface ? primaryContentTabs : []
    }
    return visibleTabs(place)
  }
  var showsContentSidePanel: Bool {
    effectiveContentLayoutMode == .split && showingRight && selected(.right) != nil
  }
  func stripPlacement(_ id: String) -> WorkspaceTabPlacement {
    let place = placement(id)
    return [.left, .right].contains(place) ? (effectiveContentLayoutMode == .full ? .left : .right) : place
  }
  func selected(_ placement: WorkspaceTabPlacement) -> WorkspaceContentTab? {
    let candidates = placement == .left ? presentedTabs(.left) : placement == .right ? primaryContentTabs : visibleTabs(placement)
    return candidates.first { $0.id == selections[placement] }
  }
  var focused: WorkspaceContentTab? {
    guard let tab = tabs.first(where: { $0.id == focusedID }), isVisible(tab.id) else { return nil }
    return tab
  }
  var commandContentTab: WorkspaceContentTab? { focused ?? selected(.left) }
  var chatVisible: Bool { selected(.left) == nil }
  var canReopen: Bool { !closed.isEmpty }
  func isVisible(_ id: String) -> Bool {
    let place = placement(id)
    if [.left, .right].contains(place) {
      if effectiveContentLayoutMode == .full { return selections[.left] == id }
      return selections[.right] == id && showingRight && !panels.showingFiles
    }
    return selections[place] == id && (place == .left || (place == .right && showingRight && !panels.showingFiles)
      || (place == .bottom && showingBottom))
  }
  func title(_ tab: WorkspaceContentTab) -> String {
    switch tab {
    case .browser(let id, _): return browser.session.tabs.first { $0.id == id }?.title ?? "浏览器"
    case .file(let path, _): return path.isEmpty ? "打开文件" : URL(fileURLWithPath: path).lastPathComponent
    case .review: return "审查"
    case .plan(let runID, _): return planDocument?(runID)?.title ?? "计划"
    case .sources: return "来源"
    case .subagents: return "子任务"
    case .pullRequest(let url, _):
      if let request = pullRequest?(url) {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Pull request #\(request.number)" : title
      }
      return "Pull Request"
    case .pullRequestWatch(let id, let target, _):
      return watchAutomation?(id, target)?.name ?? "PR 监控进度"
    case .backgroundTerminal(let id, _): return backgroundTerminalTitle?(id) ?? "后台终端"
    case .terminal(let id, _): return panels.terminals.first { $0.id == id }?.displayTitle ?? "终端"
    }
  }

  func activate(_ id: String?, focus: Bool = true) {
    guard let id else {
      contentLayoutMode = effectiveContentLayoutMode
      selections[.left] = nil; focusedID = nil
      if contentLayoutMode == .full { discardEmptyBrowserTab(resetLayout: true) }
      if focus { chatFocus = UUID() }
      return
    }
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    let place = placement(id)
    let panel = ContentTabClosePanel(place, id: id)
    closeControllers[panel, default: .init()].select(id, in: closeIDs(panel))
    if place == .left || place == .right {
      if contentLayoutMode == nil { contentLayoutMode = place == .left ? .full : .split }
      panels.showingFiles = false
      if effectiveContentLayoutMode == .full {
        selections[.left] = id
        if place == .right { selections[.right] = id }
      } else { selections[.left] = nil; selections[.right] = id; showingRight = true }
    } else { selections[place] = id; if place == .bottom { showingBottom = true } }
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
    if let id = browser.session.selection { move(WorkspaceContentTab.browser(id, owner: taskID).id, to: place) }
    openingPlacement = .left
  }
  @discardableResult private func newBrowserChild(from sourceID: UUID,
    configuration: WKWebViewConfiguration?) -> BrowserTab? {
    guard let source = tabs.first(where: { $0.browserID == sourceID }) else { return nil }
    openingPlacement = placement(source.id)
    defer { openingPlacement = .left }
    let page = browser.session.newTab(configuration: configuration, activate: false)
    let id = WorkspaceContentTab.browser(page.id, owner: taskID).id
    guard let sourceIndex = tabs.firstIndex(of: source), let childIndex = tabs.firstIndex(where: { $0.id == id }) else { return page }
    let child = tabs.remove(at: childIndex); tabs.insert(child, at: sourceIndex + 1)
    let panel = ContentTabClosePanel(placement(id), id: id)
    closeControllers[panel, default: .init()].history.opened(id, by: source.id, background: false)
    browser.visible = true
    activate(id)
    return page
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
    if !tabs.contains(tab) { tabs.append(tab); panels.workspace.selectedReviewScope = defaultScope }
    move(tab.id, to: place)
    Task { await panels.workspace.refreshGit() }
  }
  @discardableResult func openFile(_ path: String = "", in place: WorkspaceTabPlacement = .left) -> Bool {
    guard place != .bottom, let root = panels.workspace.root else { return false }
    var normalizedPath = path
    if !path.isEmpty {
      do {
        let location = try panels.workspace.fileLocation(path)
        normalizedPath = WorkspaceFileScope.key(location, primary: root)
      }
      catch { panels.workspace.fileOpenError = error.localizedDescription; return false }
    }
    let tab = WorkspaceContentTab.file(normalizedPath, owner: taskID)
    if !tabs.contains(tab) { tabs.append(tab) }
    move(tab.id, to: place)
    return true
  }
  @discardableResult func openSubagents(in place: WorkspaceTabPlacement = .right) -> Bool {
    guard place != .bottom, place != .detached else { return false }
    let tab = WorkspaceContentTab.subagents(owner: taskID)
    if tabs.contains(tab) { activate(tab.id) }
    else { tabs.append(tab); move(tab.id, to: place) }
    return true
  }
  @discardableResult func openBackgroundTerminal(_ id: UUID, in place: WorkspaceTabPlacement = .right) -> Bool {
    guard place != .bottom, place != .detached, backgroundTerminalTitle?(id) != nil else { return false }
    let tab = WorkspaceContentTab.backgroundTerminal(id, owner: taskID)
    if tabs.contains(tab) { activate(tab.id) }
    else { tabs.append(tab); move(tab.id, to: place) }
    return true
  }
  func openPlan(runID: String) {
    guard planDocument?(runID) != nil else { return }
    let tab = WorkspaceContentTab.plan(runID, owner: taskID)
    if !tabs.contains(tab) { tabs.append(tab) }
    move(tab.id, to: .left)
  }
  func openSources(in place: WorkspaceTabPlacement = .left) {
    let tab = WorkspaceContentTab.sources(owner: taskID)
    if !tabs.contains(tab) { tabs.append(tab) }
    move(tab.id, to: place)
  }
  @discardableResult func openPullRequest(_ request: GitHubPullRequest,
    in place: WorkspaceTabPlacement = .right, mergeConfirmation: Bool = false) -> Bool {
    guard place == .left || place == .right, panels.workspace.root != nil,
      pullRequest?(request.url)?.validatedURL != nil else { return false }
    let tab = WorkspaceContentTab.pullRequest(request.url, owner: taskID)
    if !tabs.contains(tab) { tabs.append(tab); move(tab.id, to: place) }
    if mergeConfirmation { pullRequestPresentations.request(tab.id) }
    activate(tab.id)
    return true
  }
  @discardableResult func openPullRequestWatch(_ watch: ShipAutomation,
    in place: WorkspaceTabPlacement = .right) -> Bool {
    guard place == .left || place == .right, let target = watch.taskID,
      watchAutomation?(watch.id, target) != nil else { return false }
    let tab = WorkspaceContentTab.pullRequestWatch(watch.id, task: target, owner: taskID)
    if let index = tabs.firstIndex(where: { $0.id == tab.id }) { tabs[index] = tab }
    else { tabs.append(tab); move(tab.id, to: place) }
    activate(tab.id)
    return true
  }
  func newTerminal(in place: WorkspaceTabPlacement = .bottom) {
    guard place != .detached, let terminal = panels.newTerminal() else { return }
    let tab = WorkspaceContentTab.terminal(terminal.id, owner: taskID)
    tabs.append(tab); placements[tab.id] = place; move(tab.id, to: place)
  }
  @discardableResult func runEnvironmentAction(_ action: EnvironmentAction,
    in place: WorkspaceTabPlacement) -> Bool {
    guard action.isRunnableOnMac, panels.workspace.root != nil else { return false }
    newTerminal(in: place)
    return panels.terminal?.run(action) == true
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
    let visible = place == .right ? showsContentSidePanel : showingBottom
    if visible, selected(place)?.terminalID != nil { hide(place); return }
    if let existing = (place == .right ? primaryContentTabs : visibleTabs(place)).first(where: { $0.terminalID != nil }) { move(existing.id, to: place) }
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
    if focusedID.map(stripPlacement) == place { activate(selected(.left)?.id) }
  }
  func canMove(_ id: String, to place: WorkspaceTabPlacement) -> Bool {
    guard let tab = tabs.first(where: { $0.id == id }), place != .detached else { return false }
    return place != .bottom || tab.terminalID != nil
  }
  func move(_ id: String, to place: WorkspaceTabPlacement) {
    guard canMove(id, to: place) else { return }
    let previous = placement(id)
    if ContentTabClosePanel(previous, id: id) != ContentTabClosePanel(place, id: id) {
      closeControllers[ContentTabClosePanel(previous, id: id), default: .init()].history.moved(id)
    }
    if place == .left { contentLayoutMode = .full; showingRight = false }
    else if place == .right { contentLayoutMode = .split; selections[.left] = nil }
    if previous != place {
      clearSelection(id); placements[id] = place
      repairSelection(previous)
    }
    activate(id)
  }
  func toggleFullWidth() {
    guard let id = (commandContentTab.flatMap { primaryContentTabs.contains($0) ? $0.id : nil })
      ?? selected(.right)?.id ?? primaryContentTabs.first(where: { $0.id == lastContentID })?.id
      ?? primaryContentTabs.first?.id else { newBrowser(); return }
    move(id, to: layoutMenu.fullViewVisible ? .right : .left)
  }
  func toggleTabLayout(_ id: String?) {
    let content = primaryContentTabs
    if let id, !content.contains(where: { $0.id == id }) { return }
    if effectiveContentLayoutMode == .full {
      let target = id ?? selected(.left)?.id
        ?? content.first(where: { $0.id == lastContentID })?.id
        ?? selected(.right)?.id ?? content.first?.id
      if let target { move(target, to: .right) }
      else { newBrowser(in: .right) }
    } else if let id {
      move(id, to: .left)
    } else {
      contentLayoutMode = .full
      showingRight = false
      activate(nil)
    }
  }
  func toggleContentVisibility() {
    if effectiveContentLayoutMode == .split, showsContentSidePanel {
      showingRight = false
      activate(nil)
      discardEmptyBrowserTab()
      return
    }
    let keepChatFocus = focused == nil && selected(.left) == nil
    let content = primaryContentTabs
    let tab = selected(.left) ?? (effectiveContentLayoutMode == .split ? selected(.right) : nil)
      ?? content.first { $0.id == lastContentID } ?? selected(.right) ?? content.first
    contentLayoutMode = .split
    if let tab {
      activate(tab.id, focus: !keepChatFocus)
      if keepChatFocus { activate(nil) }
    } else { newBrowser(in: .right) }
  }
  @discardableResult private func discardEmptyBrowserTab(resetLayout: Bool = false) -> Bool {
    guard primaryContentTabs.count == 1, let tab = primaryContentTabs.first,
      isTabPinned?(tab.id) != true, let id = tab.browserID,
      browser.session.tabs.first(where: { $0.id == id })?.canDiscardEmptyNewTab == true else { return false }
    if resetLayout {
      contentLayoutMode = .split
      showingRight = false
    }
    return browser.session.discardEmptyNewTab(id)
  }
  func close(_ id: String) {
    guard let tab = tabs.first(where: { $0.id == id }) else { return }
    if case .file = tab, canCloseFileTab?(tab) == false { return }
    pullRequestPresentations.clear(tab.id)
    onTabWillClose?(tab)
    if let browserID = tab.browserID { browser.session.close(browserID) }
    else {
      if let terminalID = tab.terminalID { panels.closeTerminal(terminalID) }
      remove(id)
    }
  }
  private func remove(_ id: String, recordCloseUndo: Bool = true) {
    if draggingTabID == id { endDrag() }
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let place = placement(id), strip = stripPlacement(id), wasFocused = focused?.id == id
    let panel = ContentTabClosePanel(place, id: id), ids = closeIDs(ContentTabClosePanel(place, id: id))
    var controller = closeControllers[panel] ?? .init()
    let current = panel == .bottom ? selections[.bottom]
      : effectiveContentLayoutMode == .full ? selections[.left] : selections[.right]
    if let current { controller.select(current, in: ids) }
    let wasSelected = controller.selectedID == id, wasLastContent = lastContentID == id
    let selectedMain = selections[.left] == id, selectedRight = selections[.right] == id, selectedBottom = selections[.bottom] == id
    let next = controller.close(id, in: ids)
    closeControllers[panel] = controller
    if recordCloseUndo {
      closed.append(Closed(tab: tabs[index], placement: place))
      if closed.count > 20 { closed.removeFirst(closed.count - 20) }
    }
    tabs.remove(at: index); placements[id] = nil; clearSelection(id)
    if wasLastContent { lastContentID = next }
    if selectedMain { selections[.left] = next }
    if selectedRight { selections[.right] = effectiveContentLayoutMode == .split ? next : nil }
    if selectedBottom { selections[.bottom] = next }
    if closeIDs(panel).isEmpty {
      if panel == .primary { showingRight = false }
      if panel == .bottom { showingBottom = false }
    }
    if wasSelected, let next, let browserID = tabs.first(where: { $0.id == next })?.browserID {
      synchronizingBrowser = true
      // Selection and native focus are separate. The focused-pane route below
      // requests focus once; closing an inactive tab must never request it.
      browser.session.select(browserID, focus: false)
      synchronizingBrowser = false
    }
    if wasFocused {
      if let next = selected(strip) { activate(next.id) }
      else { chatFocus = UUID() }
    }
  }
  private func closeIDs(_ panel: ContentTabClosePanel) -> [String] {
    tabs.filter { ContentTabClosePanel(placement($0.id), id: $0.id) == panel }.map(\.id)
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
    let candidates = place == .right ? primaryContentTabs : presentedTabs(place)
    if place != .left, selected(place) == nil {
      selections[place] = place == .right && effectiveContentLayoutMode == .full ? nil : candidates.first?.id
      if place == .right, selections[place] == nil { showingRight = false }
    }
    if candidates.isEmpty {
      if place == .right { showingRight = false }
      if place == .bottom { showingBottom = false }
    }
  }
  func closeOthers(keeping id: String?, in place: WorkspaceTabPlacement) {
    for tab in presentedTabs(place).reversed() where tab.id != id { close(tab.id) }
    activate(id)
  }
  func canCloseRight(of id: String?, in place: WorkspaceTabPlacement) -> Bool {
    let ids: [String?] = (place == .left ? [nil] : []) + presentedTabs(place).map { Optional($0.id) }
    guard let index = ids.firstIndex(of: id) else { return false }
    return index + 1 < ids.count
  }
  func closeRight(of id: String?, in place: WorkspaceTabPlacement) {
    let ids: [String?] = (place == .left ? [nil] : []) + presentedTabs(place).map { Optional($0.id) }
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
    case .file(let path, _): _ = openFile(path, in: state.placement)
    case .review: openReview(in: state.placement, defaultScope: panels.workspace.selectedReviewScope)
    case .plan(let runID, _): openPlan(runID: runID)
    case .sources: openSources(in: state.placement)
    case .pullRequest(let url, _):
      if let request = pullRequest?(url) { _ = openPullRequest(request, in: state.placement) }
    case .pullRequestWatch(let id, let target, _):
      if let watch = watchAutomation?(id, target) { _ = openPullRequestWatch(watch, in: state.placement) }
    case .subagents: _ = openSubagents(in: state.placement)
    case .backgroundTerminal(let id, _): _ = openBackgroundTerminal(id, in: state.placement)
    case .terminal: newTerminal(in: state.placement)
    }
  }
  @discardableResult func reorder(_ source: String, relativeTo target: String, after: Bool) -> Bool {
    guard source != target, stripPlacement(source) == stripPlacement(target),
      let index = tabs.firstIndex(where: { $0.id == source }), tabs.contains(where: { $0.id == target }) else { return false }
    let tab = tabs.remove(at: index)
    let destination = tabs.firstIndex(where: { $0.id == target })!
    tabs.insert(tab, at: destination + (after ? 1 : 0))
    closeControllers[ContentTabClosePanel(placement(source), id: source), default: .init()].history.moved(source)
    return true
  }
  var numberedTabIDs: [String?] {
    effectiveContentLayoutMode.numberedTabIDs(primaryContentTabs, rightToLeft: contentRightToLeft)
  }
  @discardableResult func focusSlot(_ oneBased: Int) -> Bool {
    let ids = numberedTabIDs
    guard oneBased > 0, oneBased <= ids.count else { return false }
    activate(ids[oneBased - 1])
    return true
  }
  func revealChat() {
    activate(nil)
  }
  func resetProjectTabs() {
    endDrag()
    for tab in tabs where tab.kind == .file || tab.kind == .review || tab.kind == .terminal || tab.kind == .pullRequest {
      pullRequestPresentations.clear(tab.id)
      clearSelection(tab.id); placements[tab.id] = nil
    }
    tabs.removeAll { $0.kind == .file || $0.kind == .review || $0.kind == .terminal || $0.kind == .pullRequest }
    closed.removeAll { $0.tab.kind == .file || $0.tab.kind == .review || $0.tab.kind == .terminal || $0.tab.kind == .pullRequest }
    repairSelection(.right); repairSelection(.bottom)
  }

  var layoutSnapshot: TaskWindowTabLayout {
    let saved = tabs.map { tab in
      let page = tab.browserID.flatMap { id in browser.session.tabs.first { $0.id == id } }
      let splitFraction = tab.terminalID.flatMap { id in
        panels.splitTerminals[id] == nil ? nil : panels.splitFraction(for: id)
      }
      return SavedWorkspaceTab(id: tab.id,
        kind: tab.kind,
        placement: placement(tab.id), address: page?.address,
        committedURL: tab.pullRequestURL ?? page?.committedURL?.absoluteString,
        filePath: { if case .file(let path, _) = tab { return path }; return nil }(),
        fileRoot: tab.kind == .file ? panels.workspace.root?.path : nil,
        terminalSplitFraction: splitFraction,
        watchAutomationID: tab.watchAutomationID, watchTaskID: tab.watchTaskID,
        addressInputDraftPresent: page?.savedAddressInputDraftPresent,
        browserCustomTitle: page?.customTitle)
    }
    return TaskWindowTabLayout(project: panels.workspace.root?.path,
      content: WorkspaceTabLayout(tabs: saved, active: selections[.left], right: selections[.right],
        bottom: selections[.bottom], focused: focusedID, showingInspector: showingRight,
        showingTerminal: showingBottom, showingTabs: showingTabs, side: primarySide,
        reviewScope: panels.workspace.selectedReviewScope, reviewRepository: panels.workspace.selectedReviewRepository,
        contentLayoutMode: effectiveContentLayoutMode),
      panelSizes: panels.panelSizes, showingFiles: panels.showingFiles)
  }

  /// Runs once when a window materializes a task. It never replays commands or
  /// steals focus from the window that is currently active.
  func restoreLayout(_ saved: TaskWindowTabLayout) {
    guard tabs.isEmpty else { return }
    let layout = saved.content
    let sameProject = saved.project == panels.workspace.root?.path
    var seen = Set<String>()
    for entry in layout.tabs where seen.insert(entry.id).inserted {
      let tab: WorkspaceContentTab
      switch entry.kind {
      case .browser:
        guard entry.id.hasPrefix("browser:"), let id = UUID(uuidString: String(entry.id.dropFirst(8))) else { continue }
        let page = browser.session.newTab(activate: false, id: id)
        page.setCustomTitle(entry.browserCustomTitle)
        if let raw = entry.committedURL, let url = URL(string: raw), BrowserAddress.permits(url) {
          page.address = raw
          page.navigate()
        }
        page.restoreSavedAddress(entry.address, committedURL: entry.committedURL,
          draftPresent: entry.addressInputDraftPresent)
        tab = .browser(id, owner: taskID)
      case .file:
        guard sameProject, let root = panels.workspace.root, let path = entry.filePath,
          path.isEmpty || (try? panels.workspace.fileLocation(path)) != nil else { continue }
        if let savedRoot = entry.fileRoot {
          guard savedRoot.hasPrefix("/"), !savedRoot.contains("\0"),
            GitBranchService.canonicalRoot(URL(fileURLWithPath: savedRoot)) == GitBranchService.canonicalRoot(root) else { continue }
        }
        let candidate = WorkspaceContentTab.file(path, owner: taskID)
        guard entry.id == candidate.id else { continue }
        tab = candidate; tabs.append(tab)
      case .review:
        guard sameProject, panels.workspace.root != nil,
          entry.id == WorkspaceContentTab.review(owner: taskID).id else { continue }
        tab = .review(owner: taskID)
        tabs.append(tab)
      case .plan:
        guard entry.id.hasPrefix("plan:"), entry.id.count > 5 else { continue }
        let runID = String(entry.id.dropFirst(5))
        guard planDocument?(runID) != nil else { continue }
        tab = .plan(runID, owner: taskID)
        tabs.append(tab)
      case .sources:
        guard entry.id == WorkspaceContentTab.sources(owner: taskID).id else { continue }
        tab = .sources(owner: taskID)
        tabs.append(tab)
      case .pullRequest:
        let candidate = WorkspaceContentTab.pullRequest(entry.committedURL ?? "", owner: taskID)
        guard sameProject, entry.id == candidate.id, pullRequest?(entry.committedURL ?? "")?.validatedURL != nil else { continue }
        tab = candidate; tabs.append(tab)
      case .pullRequestWatch:
        guard let id = entry.watchAutomationID, let target = entry.watchTaskID,
          watchAutomation?(id, target) != nil else { continue }
        let candidate = WorkspaceContentTab.pullRequestWatch(id, task: target, owner: taskID)
        guard candidate.id == entry.id else { continue }
        tab = candidate; tabs.append(tab)
      case .subagents:
        guard entry.id == WorkspaceContentTab.subagents(owner: taskID).id else { continue }
        tab = .subagents(owner: taskID); tabs.append(tab)
      case .backgroundTerminal:
        guard let id = WorkspaceContentTab.backgroundTerminalID(entry.id, owner: taskID),
          backgroundTerminalTitle?(id) != nil else { continue }
        tab = .backgroundTerminal(id, owner: taskID); tabs.append(tab)
      case .terminal:
        guard sameProject, entry.id.hasPrefix("terminal:"),
          let id = UUID(uuidString: String(entry.id.dropFirst(9))), panels.newTerminal(id: id) != nil else { continue }
        if let fraction = entry.terminalSplitFraction {
          _ = panels.splitTerminal(id)
          panels.setSplitFraction(fraction, for: id)
          panels.terminalFocus = nil
        }
        tab = .terminal(id, owner: taskID)
        tabs.append(tab)
      }
      placements[tab.id] = entry.placement == .detached || (entry.placement == .bottom && tab.terminalID == nil)
        ? .left : entry.placement
    }
    contentLayoutMode = layout.contentLayoutMode ?? (visibleTabs(.left).contains { $0.id == layout.active } ? .full : .split)
    func primary(_ id: String?) -> String? { primaryContentTabs.first { $0.id == id }?.id }
    selections[.left] = effectiveContentLayoutMode == .full ? primary(layout.active) : nil
    selections[.right] = primary(layout.right) ?? (effectiveContentLayoutMode == .split ? primary(layout.active) : nil)
    selections[.bottom] = visibleTabs(.bottom).first { $0.id == layout.bottom }?.id
    showingRight = layout.showingInspector && selected(.right) != nil
    showingBottom = layout.showingTerminal && !visibleTabs(.bottom).isEmpty
    showingTabs = layout.showingTabs
    primarySide = layout.side
    panels.panelSizes = saved.panelSizes
    panels.showingFiles = sameProject && panels.workspace.root != nil && saved.showingFiles
    if sameProject {
      panels.workspace.selectedReviewScope = layout.reviewScope
      panels.workspace.restoreReviewRepository(layout.reviewRepository)
    }
    focusedID = tabs.first { $0.id == layout.focused && isVisible($0.id) }?.id
    lastContentID = focusedID ?? selected(.left)?.id ?? selected(.right)?.id ?? selected(.bottom)?.id
    synchronizingBrowser = true
    if let id = [focused, selected(.left), selected(.right)].compactMap({ $0?.browserID }).first {
      browser.session.select(id, focus: false)
    }
    synchronizingBrowser = false
    if let id = [focused, selected(.bottom), selected(.right), selected(.left)].compactMap({ $0?.terminalID }).first {
      panels.selectTerminal(id, focus: false)
    }
  }

  /// If the user opened content while automation storage was loading, restore
  /// only the deferred progress tabs and retain their new selection and focus.
  func restoreDeferredWatchLayout(_ saved: TaskWindowTabLayout) {
    if tabs.isEmpty { restoreLayout(saved); return }
    for entry in saved.content.tabs where entry.kind == .pullRequestWatch {
      guard let id = entry.watchAutomationID, let target = entry.watchTaskID,
        watchAutomation?(id, target) != nil else { continue }
      let tab = WorkspaceContentTab.pullRequestWatch(id, task: target, owner: taskID)
      guard entry.id == tab.id, !tabs.contains(where: { $0.id == tab.id }) else { continue }
      tabs.append(tab)
      placements[tab.id] = entry.placement == .right ? .right : .left
    }
  }
}
