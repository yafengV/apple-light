import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ContentLayoutNavigationTests: XCTestCase {
  private struct Reference: Decodable {
    struct Transition: Decodable { let mode: String; let resultingMode: String; let resultingKind: String }
    struct Selection: Decodable { let ids: [String]; let direction: String; let handled: Bool; let selected: [String] }
    let chatTransitions: [Transition]
    let fullChatSelections: [Selection]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "content_layout_navigation_reference_692", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func store(_ root: URL) -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b"].map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.applyTaskSelection(store.library.tasks[0])
    return store
  }
  private func withStore(_ body: (WorkspaceStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(store(root))
  }

  func testMainFullViewFromChatMatchesActualReferenceSelectionAndRetainsTabOwnership() throws {
    let reference = try reference()
    for transition in reference.chatTransitions {
      XCTAssertEqual(transition.resultingMode, transition.mode)
      XCTAssertEqual(transition.resultingKind, "chat")
    }
    for sample in reference.fullChatSelections {
      try withStore { store in
        store.workspaceTabs = sample.ids.map { .file($0, owner: "a") }
        if let first = store.workspaceTabs.first { store.activateWorkspaceTab(first.id) }
        for tab in store.workspaceTabs.dropFirst() { store.workspaceTabPlacements[tab.id] = .right }
        store.workspaceTabs.append(.file("detached", owner: "a"))
        store.workspaceTabPlacements["file:a:detached"] = .detached
        store.workspaceTabs.append(.file("other", owner: "b"))
        store.activateChatTab()
        XCTAssertEqual(store.adjacentContentTab(sample.direction == "next" ? 1 : -1), sample.handled)
        let expected = sample.selected.first.map { WorkspaceContentTab.file($0, owner: "a").id }
        XCTAssertEqual(store.focusedWorkspaceTabID, expected, "\(sample.ids)/\(sample.direction)")
      }
    }
  }

  func testMainSharedControlTabAfterReturningToFullViewChatDoesNotStartRecentChatSelection() throws {
    try withStore { store in
      store.workspaceTabs = [.file("first", owner: "a"), .file("second", owner: "a")]
      store.workspaceTabPlacements[store.workspaceTabs[1].id] = .right
      store.activateWorkspaceTab(store.workspaceTabs[0].id)
      store.activateChatTab()
      store.library.recentTaskIDs = ["a", "b"]
      let controller = RecentTaskShortcutController(); controller.announce = { _ in }
      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
      XCTAssertTrue(controller.handle(event, context: store.taskNavigationShortcutContext, shortcuts: store.shortcuts))
      XCTAssertNil(controller.session)
      XCTAssertEqual(store.focusedWorkspaceTabID, store.workspaceTabs[0].id)
      XCTAssertEqual(store.selectedTask?.id, "a")
      XCTAssertTrue(store.adjacentContentTab(1))
      XCTAssertEqual(store.focusedWorkspaceTabID, store.workspaceTabs[1].id)
      XCTAssertTrue(store.adjacentContentTab(1))
      XCTAssertNil(store.focusedWorkspaceTabID)
      XCTAssertTrue(controller.handle(event, context: store.taskNavigationShortcutContext, shortcuts: store.shortcuts))
      XCTAssertNil(controller.session)
    }
  }

  func testTaskWindowFullViewCyclesAgainAfterSelectingChat() throws {
    try withStore { store in
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources(in: .left)
    XCTAssertTrue(tabs.openSubagents(in: .right))
    tabs.activate(WorkspaceContentTab.sources(owner: "a").id)
    tabs.activate(nil)
    XCTAssertTrue(tabs.navigateAdjacentContentTab(-1))
    XCTAssertEqual(tabs.focusedID, WorkspaceContentTab.subagents(owner: "a").id)
    XCTAssertTrue(tabs.navigateAdjacentContentTab(1))
    XCTAssertNil(tabs.focusedID)
    XCTAssertTrue(tabs.navigateAdjacentContentTab(1))
    XCTAssertEqual(tabs.focusedID, WorkspaceContentTab.sources(owner: "a").id)
    }
  }

  func testFullViewSelectedChatSurvivesMainAndTaskWindowLayoutRestoration() throws {
    try withStore { original in
      original.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
      original.workspaceTabPlacements[original.workspaceTabs[1].id] = .right
      original.activateWorkspaceTab(original.workspaceTabs[0].id); original.activateChatTab()
      let snapshot = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONEncoder().encode(original.workspaceTabLayoutSnapshot))
      let restored = WorkspaceStore(dataRoot: original.dataRoot.appendingPathComponent("restored"))
      restored.libraryLoaded = true; restored.scopeLoaded = true
      restored.library.tasks = original.library.tasks; restored.selection = original.selection
      restored.library.workspaceTabLayouts["a"] = snapshot
      restored.restoreWorkspaceTabLayout()
      XCTAssertNil(restored.activeWorkspaceTabID)
      XCTAssertEqual(restored.effectiveWorkspaceContentLayoutMode, .full)
      XCTAssertTrue(restored.adjacentContentTab(-1))
      XCTAssertEqual(restored.focusedWorkspaceTabID, WorkspaceContentTab.subagents(owner: "a").id)

      let resources = TaskWindowResources(); resources.prepare("a", store: original); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
      tabs.activate(WorkspaceContentTab.sources(owner: "a").id); tabs.activate(nil)
      let saved = try JSONDecoder().decode(TaskWindowTabLayout.self, from: JSONEncoder().encode(tabs.layoutSnapshot))
      let other = TaskWindowResources(); other.prepare("a", store: original); defer { other.shutdown() }
      let result = try XCTUnwrap(other.tasks["a"])
      result.restoreLayout(saved)
      XCTAssertNil(result.selected(.left))
      XCTAssertEqual(result.effectiveContentLayoutMode, .full)
      XCTAssertTrue(result.navigateAdjacentContentTab(-1))
      XCTAssertEqual(result.focusedID, WorkspaceContentTab.subagents(owner: "a").id)
    }
  }

  func testMainModeIsOwnedByTaskAndNewDraftAndSplitCommandStopsClaimingChatKeys() throws {
    try withStore { store in
      store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
      store.workspaceTabPlacements[store.workspaceTabs[1].id] = .right
      store.activateWorkspaceTab(store.workspaceTabs[0].id); store.activateChatTab()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .full)
      store.applyTaskSelection(store.library.tasks[1])
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertFalse(store.claimsAdjacentContentTabs)
      store.applyTaskSelection(store.library.tasks[0])
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .full)
      XCTAssertTrue(store.claimsAdjacentContentTabs)
      store.moveWorkspaceTab(store.workspaceTabs[0].id, to: .right)
      store.activateChatTab()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertFalse(store.claimsAdjacentContentTabs)
      store.library.recentTaskIDs = ["a", "b"]
      let controller = RecentTaskShortcutController(); controller.announce = { _ in }
      XCTAssertTrue(controller.handle(tabEvent(), context: store.taskNavigationShortcutContext, shortcuts: store.shortcuts))
      XCTAssertEqual(controller.session?.selectedID, "b")
      store.workspaceContentLayoutMode = .full
      store.newTask()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
    }
  }

  func testTaskWindowModeIsIsolatedAndMovingToSplitReturnsSharedKeysToRecentChats() throws {
    try withStore { store in
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let a = try XCTUnwrap(resources.tasks["a"])
      a.openSources(); a.activate(nil)
      resources.prepare("b", store: store)
      let b = try XCTUnwrap(resources.tasks["b"])
      XCTAssertEqual(a.effectiveContentLayoutMode, .full)
      XCTAssertTrue(a.claimsAdjacentContentTabs)
      XCTAssertEqual(b.effectiveContentLayoutMode, .split)
      XCTAssertFalse(b.claimsAdjacentContentTabs)
      a.move(WorkspaceContentTab.sources(owner: "a").id, to: .right)
      a.activate(nil)
      XCTAssertEqual(a.effectiveContentLayoutMode, .split)
      XCTAssertFalse(a.claimsAdjacentContentTabs)
      XCTAssertEqual(a.layoutSnapshot.content.contentLayoutMode, .split)
    }
  }

  func testProgrammaticTaskChatRevealPreservesModeAndContentPlacementLikeChatSelection() throws {
    try withStore { store in
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources()
      let id = WorkspaceContentTab.sources(owner: "a").id
      tabs.revealChat()
      XCTAssertTrue(tabs.chatVisible)
      XCTAssertNil(tabs.focusedID)
      XCTAssertEqual(tabs.effectiveContentLayoutMode, .full)
      XCTAssertEqual(tabs.placement(id), .left)
      XCTAssertFalse(tabs.showingRight)
      XCTAssertTrue(tabs.claimsAdjacentContentTabs)
      XCTAssertTrue(tabs.navigateAdjacentContentTab(1))
      XCTAssertEqual(tabs.focusedID, id)
    }
  }

  func testLegacyLayoutWithoutModeUsesValidSelectionAndDoesNotInventLostFullState() throws {
    try withStore { store in
      store.workspaceTabs = [.sources(owner: "a")]; store.activateWorkspaceTab(store.workspaceTabs[0].id)
      for active in [true, false] {
        if active { store.activateWorkspaceTab(store.workspaceTabs[0].id) } else { store.activateChatTab() }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.workspaceTabLayoutSnapshot)) as? [String: Any])
        object.removeValue(forKey: "contentLayoutMode")
        let old = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.contentLayoutMode)
        let cold = WorkspaceStore(dataRoot: store.dataRoot.appendingPathComponent(UUID().uuidString))
        cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
        cold.selection = store.selection; cold.library.workspaceTabLayouts["a"] = old
        cold.restoreWorkspaceTabLayout()
        XCTAssertEqual(cold.effectiveWorkspaceContentLayoutMode, active ? .full : .split)
        let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        tabs.restoreLayout(.init(project: nil, content: old, panelSizes: .init(), showingFiles: false))
        XCTAssertEqual(tabs.effectiveContentLayoutMode, active ? .full : .split)
      }
    }
  }

  func testLastContentClosedLeavesNoFullViewClaimAndNativeTaskMonitorStillCyclesFromChat() throws {
    try withStore { store in
      _ = NSApplication.shared
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); tabs.activate(nil)
      let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; let view = NSView(); window.contentView = view
      let coordinator = TaskWindowCommandKeyboardBridge.Coordinator()
      coordinator.navigationContext = .init(currentID: "a", recentIDs: ["a", "b"], isAvailable: { _ in true }, title: { $0 },
        select: { _ in XCTFail("Full-view tab must preempt recent-chat selection") },
        claimsTabs: { tabs.claimsAdjacentContentTabs }, selectTab: { tabs.navigateAdjacentContentTab($0) })
      coordinator.shortcuts = store.shortcuts; coordinator.recent.announce = { _ in }; coordinator.install(view)
      defer { coordinator.stop(); window.contentView = nil; window.close() }
      NSApplication.shared.sendEvent(tabEvent(window: window.windowNumber))
      XCTAssertEqual(tabs.focusedID, WorkspaceContentTab.sources(owner: "a").id)
      XCTAssertNil(coordinator.recent.session)
      tabs.close(WorkspaceContentTab.sources(owner: "a").id)
      XCTAssertFalse(tabs.claimsAdjacentContentTabs)
      XCTAssertFalse(tabs.navigateAdjacentContentTab(1))
      XCTAssertFalse(window.isVisible)
    }
  }
  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  func testHiddenActualWorkspaceAndTaskViewsMountFullContentOnceAndUnmountItForChat() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = store(root)
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let first = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(in: .right)
    let right = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == right.browserID })
    store.activateWorkspaceTab(first.id); store.activateWorkspaceTab(right.id)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let tracker = NoticeHostBoundsTracker()
    let host = NSHostingView(rootView: WorkspaceView(store: store)
      .coordinateSpace(name: NoticeHostBounds.coordinateSpace)
      .environment(\.noticeHostBoundsTracker, tracker))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(page.view.window === window)
    XCTAssertGreaterThan(page.view.bounds.width, 800)
    XCTAssertEqual(try XCTUnwrap(tracker.bounds.workspace).width, try XCTUnwrap(tracker.bounds.detail).width, accuracy: 1)
    store.activateChatTab()
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertNil(page.view.window)
    XCTAssertFalse(store.browserVisible)
    XCTAssertTrue(store.adjacentContentTab(-1))
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(page.view.window === window)
    XCTAssertGreaterThan(page.view.bounds.width, 800)
    XCTAssertEqual(store.workspaceTabPlacement(right.id), .right)
    XCTAssertFalse(window.isVisible)

    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let taskFirst = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(in: .right); let taskRight = try XCTUnwrap(tabs.selected(.right))
    let taskPage = try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == taskRight.browserID })
    tabs.activate(taskFirst.id); tabs.activate(taskRight.id)
    let taskWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    taskWindow.isReleasedWhenClosed = false
    defer { taskWindow.contentView = nil; taskWindow.close() }
    let taskHost = NSHostingView(rootView: TaskWindowView(store: store, taskID: "a", tabs: tabs,
      resources: resources, renameHistory: TaskRenameHistory(), onNavigate: { _ in },
      canGoBack: false, canGoForward: false, onMove: { _ in }))
    taskWindow.contentView = taskHost
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(taskPage.view.window === taskWindow)
    XCTAssertGreaterThan(taskPage.view.bounds.width, 900)
    tabs.activate(nil)
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertNil(taskPage.view.window)
    XCTAssertTrue(tabs.navigateAdjacentContentTab(-1))
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(taskPage.view.window === taskWindow)
    XCTAssertGreaterThan(taskPage.view.bounds.width, 900)
    XCTAssertEqual(tabs.placement(taskRight.id), .right)
    XCTAssertFalse(taskWindow.isVisible)
  }
  func testFullViewPresentsPreviouslyRightContentInMainAndRestoresIt() throws {
    try withStore { store in
      store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a")]
      let first = store.workspaceTabs[0].id, second = store.workspaceTabs[1].id
      store.workspaceTabPlacements[second] = .right
      store.activateWorkspaceTab(first)
      store.activateWorkspaceTab(second)
      XCTAssertEqual(store.activeWorkspaceContentTab?.id, second)
      XCTAssertEqual(store.workspaceTabPlacement(second), .right)
      XCTAssertEqual(store.presentedWorkspaceContentTabs(in: .left).map(\.id), [first, second])
      XCTAssertTrue(store.presentedWorkspaceContentTabs(in: .right).isEmpty)
      XCTAssertFalse(store.showsWorkspaceInspector)
      store.activateChatTab()
      XCTAssertNil(store.activeWorkspaceContentTab)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertTrue(store.adjacentContentTab(-1))
      XCTAssertEqual(store.activeWorkspaceContentTab?.id, second)
      let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONEncoder().encode(store.workspaceTabLayoutSnapshot))
      let cold = WorkspaceStore(dataRoot: store.dataRoot.appendingPathComponent("full-cold"))
      cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
      cold.selection = store.selection; cold.library.workspaceTabLayouts["a"] = saved
      cold.restoreWorkspaceTabLayout()
      XCTAssertEqual(cold.activeWorkspaceContentTab?.id, second)
      XCTAssertEqual(cold.focusedWorkspaceContentTab?.id, second)
      XCTAssertEqual(cold.workspaceTabPlacement(second), .right)
      XCTAssertFalse(cold.showsWorkspaceInspector)
    }
  }

  func testTaskFullViewPresentsPreviouslyRightContentInMainAndRestoresIt() throws {
    try withStore { store in
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
      let first = WorkspaceContentTab.sources(owner: "a").id, second = WorkspaceContentTab.subagents(owner: "a").id
      tabs.activate(first); tabs.activate(second)
      XCTAssertEqual(tabs.selected(.left)?.id, second)
      XCTAssertFalse(tabs.chatVisible)
      XCTAssertTrue(tabs.isVisible(second))
      XCTAssertFalse(tabs.isVisible(first))
      XCTAssertEqual(tabs.placement(second), .right)
      XCTAssertEqual(tabs.presentedTabs(.left).map(\.id), [first, second])
      XCTAssertTrue(tabs.presentedTabs(.right).isEmpty)
      XCTAssertFalse(tabs.showsContentSidePanel)
      tabs.activate(nil)
      XCTAssertTrue(tabs.chatVisible)
      XCTAssertFalse(tabs.isVisible(second))
      XCTAssertTrue(tabs.navigateAdjacentContentTab(-1))
      XCTAssertEqual(tabs.selected(.left)?.id, second)
      let saved = try JSONDecoder().decode(TaskWindowTabLayout.self, from: JSONEncoder().encode(tabs.layoutSnapshot))
      let other = TaskWindowResources(); other.prepare("a", store: store); defer { other.shutdown() }
      let cold = try XCTUnwrap(other.tasks["a"]); cold.restoreLayout(saved)
      XCTAssertEqual(cold.selected(.left)?.id, second)
      XCTAssertEqual(cold.focused?.id, second)
      XCTAssertTrue(cold.isVisible(second))
      XCTAssertFalse(cold.isVisible(first))
      XCTAssertFalse(cold.showsContentSidePanel)
    }
  }

  func testFullStripCloseAndReorderIncludeRightContentAndExcludeBottomAndOtherOwners() throws {
    try withStore { store in
      store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a"), .file("other", owner: "b")]
      let first = store.workspaceTabs[0].id, second = store.workspaceTabs[1].id
      store.workspaceTabPlacements[second] = .right
      store.activateWorkspaceTab(first)
      let bottom = WorkspaceContentTab.terminal(UUID(), owner: "a")
      let detached = WorkspaceContentTab.file("detached", owner: "a")
      store.workspaceTabs += [bottom, detached]
      store.workspaceTabPlacements[bottom.id] = .bottom
      store.workspaceTabPlacements[detached.id] = .detached
      XCTAssertFalse(store.reorderWorkspaceTab(bottom.id, relativeTo: first, after: false))
      XCTAssertFalse(store.reorderWorkspaceTab("file:b:other", relativeTo: first, after: false))
      XCTAssertTrue(store.reorderWorkspaceTab(second, relativeTo: first, after: false))
      XCTAssertEqual(store.presentedWorkspaceContentTabs(in: .left).map(\.id), [second, first])
      XCTAssertTrue(store.canCloseWorkspaceTabsToRight(of: second))
      store.closeWorkspaceTabsToRight(of: second)
      XCTAssertEqual(store.activeWorkspaceContentTab?.id, second)
      XCTAssertTrue(store.workspaceTabs.contains { $0.owner == "b" })
      store.closeOtherWorkspaceTabs(keeping: nil)
      XCTAssertEqual(Set(store.visibleWorkspaceContentTabs.map(\.id)), [bottom.id, detached.id])
      XCTAssertFalse(store.claimsAdjacentContentTabs)
      XCTAssertFalse(store.adjacentContentTab(1))

      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
      tabs.activate(first)
      XCTAssertTrue(tabs.reorder(second, relativeTo: first, after: false))
      XCTAssertEqual(tabs.presentedTabs(.left).map(\.id), [second, first])
      XCTAssertTrue(tabs.canCloseRight(of: second, in: .left))
      tabs.closeRight(of: second, in: .left)
      XCTAssertEqual(tabs.selected(.left)?.id, second)
      tabs.closeOthers(keeping: nil, in: .left)
      XCTAssertTrue(tabs.tabs.isEmpty)
      XCTAssertFalse(tabs.claimsAdjacentContentTabs)
    }
  }

  func testFullViewToggleFromChatUsesLayoutModeRatherThanPhysicalPlacement() throws {
    try withStore { store in
      store.workspaceTabs = [.sources(owner: "a")]
      let id = store.workspaceTabs[0].id
      store.activateWorkspaceTab(id); store.activateChatTab()
      store.toggleWorkspaceTabView()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertEqual(store.activeRightWorkspaceContentTab?.id, id)
      XCTAssertNil(store.activeWorkspaceContentTab)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); tabs.activate(nil); tabs.toggleFullWidth()
      XCTAssertEqual(tabs.effectiveContentLayoutMode, .split)
      XCTAssertEqual(tabs.selected(.right)?.id, id)
      tabs.toggleFullWidth()
      XCTAssertEqual(tabs.effectiveContentLayoutMode, .full)
      XCTAssertEqual(tabs.selected(.left)?.id, id)
    }
  }

  func testInspectorToolbarRevealsHiddenFullContentAndSwapOnlyUsesPresentedPanels() throws {
    try withStore { store in
      store.newBrowserTab(in: .right)
      let right = try XCTUnwrap(store.activeRightWorkspaceContentTab)
      store.newBrowserTab()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .full)
      XCTAssertFalse(store.showsWorkspaceInspector)
      XCTAssertFalse(store.commandEnabled("workspace-swap-panes"))
      store.toggleWorkspaceInspector()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertTrue(store.showsWorkspaceInspector)
      XCTAssertEqual(store.activeRightWorkspaceContentTab, right)
      XCTAssertNil(store.activeWorkspaceContentTab)
      store.toggleWorkspaceInspector()
      XCTAssertFalse(store.showsWorkspaceInspector)
      store.showPane("browser")
      XCTAssertTrue(store.showsWorkspaceInspector)
      XCTAssertTrue(store.commandEnabled("workspace-swap-panes"))
      store.workspaceContentLayoutMode = .full; store.activeRightWorkspaceTabID = nil
      store.toggleWorkspaceInspector()
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertTrue(store.showsWorkspaceInspector)
      store.workspace.browser.shutdown()
    }
  }
  private func tabEvent(window: Int = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
      windowNumber: window, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
  }
}
