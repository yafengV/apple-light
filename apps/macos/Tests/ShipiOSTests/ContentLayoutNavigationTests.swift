import AppKit
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
  private func tabEvent(window: Int = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
      windowNumber: window, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
  }
}
