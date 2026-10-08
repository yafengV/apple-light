import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SplitContentPresentationTests: XCTestCase {
  private struct Reference: Decodable {
    struct Selection: Decodable {
      let ids: [String]; let current: String?; let direction: String; let handled: Bool; let selected: [String]
    }
    struct Dispatch: Decodable {
      let mode: String; let origin: String; let visible: Bool; let handled: Bool; let calls: [String]
    }
    let selections: [Selection]
    let dispatches: [Dispatch]
  }
  private func fixture() throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "a", runIDs: [])]
    store.applyTaskSelection(store.library.tasks[0])
    return (store, root)
  }

  func testMainSplitUsesWholeContentPoolWithoutChangingModeWhenSelectingOldLeftTab() throws {
    let (store, _) = try fixture()
    store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
    let first = store.workspaceTabs[0].id, second = store.workspaceTabs[1].id
    store.moveWorkspaceTab(first, to: .left); store.moveWorkspaceTab(second, to: .right)
    XCTAssertTrue(store.presentedWorkspaceContentTabs(in: .left).isEmpty)
    XCTAssertEqual(store.presentedWorkspaceContentTabs(in: .right).map(\.id), [first, second])
    store.activateWorkspaceTab(first)
    XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.id, first)
    XCTAssertEqual(store.focusedWorkspaceContentTab?.id, first)
    XCTAssertEqual(store.workspaceTabPlacement(first), .left)
    store.activateChatTab()
    XCTAssertTrue(store.showsWorkspaceInspector)
    XCTAssertFalse(store.claimsAdjacentContentTabs)
    XCTAssertFalse(store.adjacentContentTab(1))
  }

  func testTaskSplitUsesWholeContentPoolWithoutChangingModeWhenSelectingOldLeftTab() throws {
    let (store, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
    let first = WorkspaceContentTab.sources(owner: "a").id, second = WorkspaceContentTab.subagents(owner: "a").id
    XCTAssertTrue(tabs.presentedTabs(.left).isEmpty)
    XCTAssertEqual(tabs.presentedTabs(.right).map(\.id), [first, second])
    tabs.activate(first)
    XCTAssertEqual(tabs.effectiveContentLayoutMode, .split)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertEqual(tabs.selected(.right)?.id, first)
    XCTAssertEqual(tabs.focused?.id, first)
    XCTAssertEqual(tabs.placement(first), .left)
    tabs.activate(nil)
    XCTAssertTrue(tabs.showsContentSidePanel)
    XCTAssertFalse(tabs.claimsAdjacentContentTabs)
    XCTAssertFalse(tabs.navigateAdjacentContentTab(1))
  }

  func testMainSplitMatchesActualReferenceSelectionTracesAcrossSavedPlacements() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "split_content_navigation_reference_694", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.selections.count, 10)
    for sample in reference.selections {
      let (store, _) = try fixture()
      store.workspaceTabs = sample.ids.map { .file($0, owner: "a") }
      if sample.ids.count > 1 { store.workspaceTabPlacements[store.workspaceTabs[1].id] = .right }
      store.workspaceContentLayoutMode = .split
      if let current = sample.current { store.activateWorkspaceTab(WorkspaceContentTab.file(current, owner: "a").id) }
      XCTAssertEqual(store.adjacentContentTab(sample.direction == "next" ? 1 : -1), sample.handled)
      let expected = (sample.selected.first ?? sample.current).map { WorkspaceContentTab.file($0, owner: "a").id }
      XCTAssertEqual(store.focusedWorkspaceContentTab?.id, expected)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertNil(store.activeWorkspaceContentTab)
    }
  }

  func testSplitSideSelectionOfOldLeftTabRoundTripsInBothWindows() throws {
    let (store, root) = try fixture()
    store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
    store.moveWorkspaceTab(store.workspaceTabs[0].id, to: .left)
    store.moveWorkspaceTab(store.workspaceTabs[1].id, to: .right)
    store.activateWorkspaceTab(store.workspaceTabs[0].id)
    let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONEncoder().encode(store.workspaceTabLayoutSnapshot))
    let cold = WorkspaceStore(dataRoot: root.appendingPathComponent("cold"))
    cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
    cold.selection = "a"; cold.library.workspaceTabLayouts["a"] = saved; cold.restoreWorkspaceTabLayout()
    XCTAssertEqual(cold.effectiveWorkspaceContentLayoutMode, .split)
    XCTAssertNil(cold.activeWorkspaceContentTab)
    XCTAssertEqual(cold.activeRightWorkspaceContentTab, .sources(owner: "a"))
    XCTAssertEqual(cold.focusedWorkspaceContentTab, .sources(owner: "a"))
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources(); XCTAssertTrue(tabs.openSubagents()); tabs.activate(WorkspaceContentTab.sources(owner: "a").id)
    let layout = try JSONDecoder().decode(TaskWindowTabLayout.self, from: JSONEncoder().encode(tabs.layoutSnapshot))
    let other = TaskWindowResources(); other.prepare("a", store: store); defer { other.shutdown() }
    let restored = try XCTUnwrap(other.tasks["a"]); restored.restoreLayout(layout)
    XCTAssertEqual(restored.effectiveContentLayoutMode, .split)
    XCTAssertNil(restored.selected(.left))
    XCTAssertEqual(restored.selected(.right), .sources(owner: "a"))
    XCTAssertEqual(restored.focused, .sources(owner: "a"))
  }

  func testTaskSplitMatchesActualReferenceSelectionsWithoutCyclingThroughChat() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "split_content_navigation_reference_694", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    for sample in reference.selections {
      let (store, root) = try fixture()
      store.library.tasks[0].project = root.path
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      for (index, name) in sample.ids.enumerated() {
        try Data().write(to: root.appendingPathComponent(name))
        XCTAssertTrue(tabs.openFile(name, in: index == 1 ? .right : .left))
      }
      tabs.contentLayoutMode = .split
      if let current = sample.current { tabs.activate(WorkspaceContentTab.file(current, owner: "a").id) }
      XCTAssertEqual(tabs.navigateAdjacentContentTab(sample.direction == "next" ? 1 : -1), sample.handled)
      let expected = (sample.selected.first ?? sample.current).map { WorkspaceContentTab.file($0, owner: "a").id }
      XCTAssertEqual(tabs.focused?.id, expected)
      XCTAssertTrue(tabs.chatVisible)
      XCTAssertEqual(tabs.effectiveContentLayoutMode, .split)
    }
  }

  func testSplitCloseReorderAndHideUseThePresentedPoolInBothWindows() throws {
    let (store, _) = try fixture()
    store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a"), .file("other", owner: "b")]
    let first = store.workspaceTabs[0].id, second = store.workspaceTabs[1].id
    store.moveWorkspaceTab(first, to: .left); store.moveWorkspaceTab(second, to: .right)
    XCTAssertTrue(store.reorderWorkspaceTab(second, relativeTo: first, after: false))
    store.closeWorkspaceTabsToRight(of: second)
    XCTAssertEqual(store.presentedWorkspaceContentTabs(in: .right).map(\.id), [second])
    XCTAssertTrue(store.workspaceTabs.contains { $0.owner == "b" })
    store.toggleWorkspaceInspector()
    XCTAssertNil(store.focusedWorkspaceContentTab)
    XCTAssertFalse(store.claimsAdjacentContentTabs)
    store.toggleWorkspaceInspector()
    XCTAssertEqual(store.focusedWorkspaceContentTab?.id, second)
    store.closeWorkspaceTab(second)
    XCTAssertTrue(store.workspacePrimaryContentTabs.isEmpty)
    XCTAssertFalse(store.claimsAdjacentContentTabs)

    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
    XCTAssertTrue(tabs.reorder(second, relativeTo: first, after: false))
    tabs.closeRight(of: second, in: .right)
    XCTAssertEqual(tabs.presentedTabs(.right).map(\.id), [second])
    tabs.hide(.right)
    XCTAssertFalse(tabs.claimsAdjacentContentTabs)
    tabs.activate(second)
    tabs.close(second)
    XCTAssertFalse(tabs.showsContentSidePanel)
    XCTAssertTrue(tabs.chatVisible)
  }

  func testHiddenActualViewsKeepChatAndMountOneSideBrowserWhenSelectingOldLeftTab() async throws {
    _ = NSApplication.shared
    let (store, _) = try fixture()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let first = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(in: .right); let second = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == first.browserID })
    let other = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == second.browserID })
    store.activateWorkspaceTab(first.id)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let tracker = NoticeHostBoundsTracker()
    let host = NSHostingView(rootView: WorkspaceView(store: store)
      .coordinateSpace(name: NoticeHostBounds.coordinateSpace).environment(\.noticeHostBoundsTracker, tracker))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(page.view.window === window)
    XCTAssertNil(other.view.window)
    XCTAssertLessThan(page.view.bounds.width, 600)
    XCTAssertLessThan(try XCTUnwrap(tracker.bounds.workspace).width, try XCTUnwrap(tracker.bounds.detail).width)
    let oldX = page.view.convert(.zero, to: host).x, oldWidth = page.view.bounds.width
    store.swapWorkspacePanes()
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(abs(page.view.convert(.zero, to: host).x - oldX), 20)
    XCTAssertEqual(page.view.bounds.width, oldWidth, accuracy: 1)
    func editors(_ view: NSView) -> [ComposerNativeTextView] {
      ((view as? ComposerNativeTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
    }
    let editor = try XCTUnwrap(editors(host).first)
    XCTAssertTrue(window.makeFirstResponder(editor))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(store.focusedWorkspaceContentTab)
    XCTAssertFalse(store.claimsAdjacentContentTabs)
    store.activateChatTab()
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(page.view.window === window, "Choosing chat retains the split content")
    XCTAssertFalse(store.claimsAdjacentContentTabs)
    XCTAssertFalse(window.isVisible)

    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let taskFirst = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(in: .right); let taskSecond = try XCTUnwrap(tabs.selected(.right))
    let taskPage = try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == taskFirst.browserID })
    let taskOther = try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == taskSecond.browserID })
    tabs.activate(taskFirst.id)
    let taskWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    taskWindow.isReleasedWhenClosed = false
    defer { taskWindow.contentView = nil; taskWindow.close() }
    let taskHost = NSHostingView(rootView: TaskWindowView(store: store, taskID: "a", tabs: tabs,
      resources: resources, renameHistory: TaskRenameHistory(), onNavigate: { _ in },
      canGoBack: false, canGoForward: false, onMove: { _ in }))
    taskWindow.contentView = taskHost
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(taskPage.view.window === taskWindow)
    XCTAssertNil(taskOther.view.window)
    XCTAssertLessThan(taskPage.view.bounds.width, 600)
    XCTAssertTrue(tabs.chatVisible)
    let taskOldX = taskPage.view.convert(.zero, to: taskHost).x
    tabs.primarySide.swap()
    try await Task.sleep(for: .milliseconds(100)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(abs(taskPage.view.convert(.zero, to: taskHost).x - taskOldX), 20)
    let taskEditor = try XCTUnwrap(editors(taskHost).first)
    XCTAssertTrue(taskWindow.makeFirstResponder(taskEditor))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(tabs.focused)
    tabs.activate(nil)
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(taskPage.view.window === taskWindow)
    XCTAssertFalse(tabs.claimsAdjacentContentTabs)
    XCTAssertFalse(taskWindow.isVisible)
  }

  func testSplitPanelDispatchMatchesReferenceForMainSideAndHiddenContent() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "split_content_navigation_reference_694", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.dispatches.count, 12)
    for sample in reference.dispatches where sample.mode == "split" && sample.origin != "bottom" {
      let (store, _) = try fixture()
      store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
      store.moveWorkspaceTab(store.workspaceTabs[1].id, to: .right)
      if sample.origin == "main" { store.activateChatTab() }
      store.showingInspector = sample.visible
      XCTAssertEqual(store.adjacentContentTab(1), sample.handled)
      XCTAssertEqual(sample.calls.isEmpty, !sample.handled)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
      if sample.origin == "main" { tabs.activate(nil) }
      tabs.showingRight = sample.visible
      XCTAssertEqual(tabs.navigateAdjacentContentTab(1), sample.handled)
    }
  }

  func testTerminalFocusFollowsPresentedSplitAndFullContentAndReleasesOnChat() throws {
    let (store, root) = try fixture()
    store.project = root; store.workspace.setProject(root)
    defer { store.workspace.terminals.shutdown() }
    store.newTerminalTab(in: .left)
    let terminal = try XCTUnwrap(store.activeWorkspaceContentTab)
    let id = try XCTUnwrap(terminal.terminalID)
    let session = try XCTUnwrap(store.terminalSession(id)), pid = session.view.process.shellPid
    store.workspaceTabs.append(.subagents(owner: "a"))
    store.moveWorkspaceTab(WorkspaceContentTab.subagents(owner: "a").id, to: .right)
    store.activateWorkspaceTab(terminal.id)
    XCTAssertEqual(store.workspaceTabPlacement(terminal.id), .left)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, terminal)
    let splitRequest = try XCTUnwrap(store.terminalFocusRequest)
    XCTAssertTrue(store.canFocusTerminal(splitRequest))
    store.activateChatTab()
    XCTAssertFalse(store.canFocusTerminal(splitRequest))
    store.moveWorkspaceTab(terminal.id, to: .right)
    store.moveWorkspaceTab(WorkspaceContentTab.subagents(owner: "a").id, to: .left)
    store.activateWorkspaceTab(terminal.id)
    XCTAssertEqual(store.workspaceTabPlacement(terminal.id), .right)
    XCTAssertEqual(store.activeWorkspaceContentTab, terminal)
    let fullRequest = try XCTUnwrap(store.terminalFocusRequest)
    XCTAssertTrue(store.canFocusTerminal(fullRequest))
    store.activateChatTab()
    XCTAssertFalse(store.canFocusTerminal(fullRequest))
    XCTAssertTrue(store.terminalSession(id) === session)
    XCTAssertEqual(session.view.process.shellPid, pid)
    XCTAssertTrue(session.view.process.running)
  }
}
