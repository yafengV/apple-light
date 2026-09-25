import XCTest

@testable import ShipiOS

@MainActor final class WorkspaceTabTests: XCTestCase {
  private func storeWithTask() -> WorkspaceStore {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["run"])
    ]
    store.selection = "run"
    return store
  }

  private func storeWithTerminalTask() -> WorkspaceStore {
    let store = WorkspaceStore()
    let root = GitBranchService.canonicalRoot(URL(fileURLWithPath: "/tmp"))
    store.project = root
    store.library.tasks = [
      .init(id: "task", project: root.path, title: "Task", runIDs: ["run"])
    ]
    store.selection = "run"
    return store
  }

  func testChatBrowserAndReviewShareOneOrderedTaskTabStrip() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }

    store.newBrowserTab()
    let first = try XCTUnwrap(store.workspace.browser.selected)
    store.newBrowserTab()
    let second = try XCTUnwrap(store.workspace.browser.selected)
    store.openReviewTab()

    XCTAssertEqual(store.visibleWorkspaceContentTabs.map(\.id), [
      "browser:\(first.id.uuidString)", "browser:\(second.id.uuidString)", "review:task",
    ])
    XCTAssertEqual(store.activeWorkspaceTabID, "review:task")
    store.focusWorkspaceTab(at: 0)
    XCTAssertNil(store.activeWorkspaceTabID)
    store.focusWorkspaceTab(at: 1)
    XCTAssertEqual(store.activeBrowserTabID, first.id)
    store.moveWorkspaceTab(-1)
    XCTAssertNil(store.activeWorkspaceTabID)
    store.moveWorkspaceTab(-1)
    XCTAssertEqual(store.activeWorkspaceTabID, "review:task")
  }

  func testContentTabsReorderCloseRightCloseOthersAndReopen() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let first = try XCTUnwrap(store.workspace.browser.selected)
    store.newBrowserTab()
    let second = try XCTUnwrap(store.workspace.browser.selected)
    store.openReviewTab()

    XCTAssertTrue(store.reorderWorkspaceTab("review:task", relativeTo: "browser:\(first.id.uuidString)", after: false))
    XCTAssertEqual(store.visibleWorkspaceContentTabs.map(\.id), [
      "review:task", "browser:\(first.id.uuidString)", "browser:\(second.id.uuidString)",
    ])
    store.closeWorkspaceTabsToRight(of: "browser:\(first.id.uuidString)")
    XCTAssertEqual(store.visibleWorkspaceContentTabs.map(\.id), [
      "review:task", "browser:\(first.id.uuidString)",
    ])
    XCTAssertTrue(second.closed)
    XCTAssertTrue(store.canReopenClosedWorkspaceTab)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.visibleWorkspaceContentTabs.count, 3)
    let reopened = try XCTUnwrap(store.activeBrowserTabID)
    XCTAssertNotEqual(reopened, second.id)

    store.closeOtherWorkspaceTabs(keeping: "review:task")
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [.review(owner: "task")])
    XCTAssertEqual(store.activeWorkspaceTabID, "review:task")
    XCTAssertTrue(first.closed)
  }

  func testTabsAreScopedToTaskAndSettingsPreserveTheActiveContentTab() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let browser = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.openSettings(.general)
    XCTAssertEqual(store.activeWorkspaceContentTab, browser)
    XCTAssertFalse(store.browserVisible)
    store.closeSettings()
    XCTAssertEqual(store.activeWorkspaceContentTab, browser)
    XCTAssertTrue(store.browserVisible)

    store.library.tasks.append(
      .init(id: "other", project: "/project", title: "Other", runIDs: ["other-run"]))
    store.applyTaskSelection(store.library.tasks[1])
    XCTAssertTrue(store.visibleWorkspaceContentTabs.isEmpty)
    XCTAssertNil(store.activeWorkspaceContentTab)
    store.applyTaskSelection(store.library.tasks[0])
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [browser])
  }

  func testCodexTabCommandsUseExactPositionsAndOnlyCloseContent() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    store.openReviewTab()

    store.executeCommand("focus-tab-1")
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertFalse(store.commandEnabled("tab-close"))
    store.executeCommand("focus-tab-3")
    XCTAssertEqual(store.activeWorkspaceTabID, "review:task")
    XCTAssertTrue(store.commandEnabled("tab-close"))
    store.executeCommand("tab-close")
    XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertEqual(store.visibleWorkspaceContentTabs.count, 1)
    XCTAssertEqual(store.shortcuts.label("focus-tab-1"), "⌘1")
    XCTAssertEqual(store.shortcuts.label("tab-close-others"), "⌥⌘W")
  }

  func testNewDraftContentTabsMigrateToCreatedTaskOwner() throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/project")
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let browserID = try XCTUnwrap(store.activeBrowserTabID)
    XCTAssertEqual(store.visibleWorkspaceContentTabs.first?.owner, "new:/project")

    store.library.tasks = [
      .init(id: "created", project: "/project", title: "Created", runIDs: ["run"])
    ]
    store.selection = "run"
    store.moveWorkspaceTabs(from: "new:/project", to: "created")
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [.browser(browserID, owner: "created")])
    XCTAssertEqual(store.activeBrowserTabID, browserID)
  }

  func testContentTabPinLivesInPinnedSidebarAndCanBeRestored() async throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)

    store.pinWorkspaceTab(source.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.sourceTabID, source.id)
    XCTAssertEqual(pin.owner, "task")
    XCTAssertEqual(pin.kind, .browser)
    XCTAssertEqual(
      store.library.sidebarItems(in: SidebarLayout.pinned), [.contentTab(pin.id)])
    XCTAssertTrue(store.isWorkspaceTabPinned(source.id))

    store.closeWorkspaceTab(source.id)
    XCTAssertFalse(store.pinnedWorkspaceTabIsLive(pin))
    await store.openPinnedWorkspaceTab(pin.id)
    let restored = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertNotEqual(restored.id, source.id)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, restored.id)
    XCTAssertTrue(store.pinnedWorkspaceTabIsLive(try XCTUnwrap(store.library.pinnedContentTabs.first)))

    store.unpinWorkspaceTab(restored.id)
    XCTAssertTrue(store.library.pinnedContentTabs.isEmpty)
    XCTAssertTrue(store.library.sidebarItems(in: SidebarLayout.pinned).isEmpty)
  }

  func testPinnedReviewReferencePersistsAcrossLibraryEncoding() throws {
    let store = storeWithTask()
    store.openReviewTab()
    store.pinWorkspaceTab("review:task")
    let decoded = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    let pin = try XCTUnwrap(decoded.pinnedContentTabs.first)
    XCTAssertEqual(pin.kind, .review)
    XCTAssertEqual(pin.sourceTabID, "review:task")
    XCTAssertEqual(decoded.sidebarItems(in: SidebarLayout.pinned), [.contentTab(pin.id)])
  }

  func testContentTabMovesBetweenMainRightAndDetachedWithoutRecreatingBrowser() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    let browserID = try XCTUnwrap(source.browserID)
    let browser = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == browserID })

    store.moveWorkspaceTab(source.id, to: .right)
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, source)
    XCTAssertTrue(store.showingInspector)
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)

    store.moveWorkspaceTab(source.id, to: .detached)
    XCTAssertNil(store.activeRightWorkspaceContentTab)
    XCTAssertEqual(store.workspaceTabPlacement(source.id), .detached)
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)

    store.restoreDetachedWorkspaceTab(source.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, source)
    XCTAssertEqual(store.workspaceTabPlacement(source.id), .left)
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)
  }

  func testContentTabDragTracksPaneAndNewWindowTargetsUntilItEnds() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)

    store.beginWorkspaceTabDrag(source.id)
    XCTAssertEqual(store.draggingWorkspaceTabID, source.id)
    XCTAssertNil(store.workspaceTabDropTarget)
    store.workspaceTabDropTarget = .placement(.right)
    XCTAssertEqual(store.workspaceTabDropTarget, .placement(.right))
    store.workspaceTabDropTarget = .newWindow
    XCTAssertEqual(store.workspaceTabDropTarget, .newWindow)
    store.workspaceTabDropTarget = .pin
    XCTAssertEqual(store.workspaceTabDropTarget, .pin)
    store.workspaceTabDropTarget = .chat("other")
    XCTAssertEqual(store.workspaceTabDropTarget, .chat("other"))
    store.workspaceTabDropTarget = .newChat
    XCTAssertEqual(store.workspaceTabDropTarget, .newChat)

    store.endWorkspaceTabDrag()
    XCTAssertNil(store.draggingWorkspaceTabID)
    XCTAssertNil(store.workspaceTabDropTarget)

    store.beginWorkspaceTabDrag("missing")
    XCTAssertNil(store.draggingWorkspaceTabID)
  }

  func testBrowserTabMovesToExistingTaskWithoutRecreatingItsWebView() async throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.library.tasks.append(
      .init(id: "other", project: "/project", title: "Other", runIDs: ["other-run"]))
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    let browserID = try XCTUnwrap(source.browserID)
    let browser = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == browserID })
    store.pinWorkspaceTab(source.id)

    let moved = await store.moveWorkspaceTab(source.id, toTaskID: "other")
    XCTAssertTrue(moved)

    XCTAssertEqual(store.currentWorkspaceTabOwner, "other")
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [.browser(browserID, owner: "other")])
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.owner, "other")
    XCTAssertEqual(store.focusedWorkspaceTabID, source.id)
  }

  func testBrowserTabMovesToNewChatDraftAndKeepsItsWebView() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.project = URL(fileURLWithPath: "/project")
    store.library.tasks = [
      .init(id: "task", project: "/project", title: "Task", runIDs: ["run"])
    ]
    store.selection = "run"
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)
    let browserID = try XCTUnwrap(source.browserID)
    let browser = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == browserID })

    let moved = await store.moveWorkspaceTabToNewTask(source.id)

    XCTAssertTrue(moved)
    XCTAssertNil(store.project)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.currentWorkspaceTabOwner, "new:none")
    XCTAssertEqual(store.visibleWorkspaceContentTabs, [.browser(browserID, owner: "new:none")])
    XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == browserID } === browser)
    XCTAssertEqual(store.focusedWorkspaceTabID, source.id)
  }

  func testReviewMoveRekeysLayoutSelectionAndPinnedReference() throws {
    let store = storeWithTask()
    store.openReviewTab(in: .right)
    store.pinWorkspaceTab("review:task")

    let migrated = store.moveWorkspaceTab("review:task", toOwner: "other")

    XCTAssertEqual(migrated, "review:other")
    XCTAssertEqual(store.workspaceTabs, [.review(owner: "other")])
    XCTAssertEqual(store.workspaceTabPlacement("review:other"), .right)
    XCTAssertEqual(store.activeRightWorkspaceTabID, "review:other")
    XCTAssertEqual(store.focusedWorkspaceTabID, "review:other")
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, "review:other")
    XCTAssertEqual(store.library.pinnedContentTabs.first?.owner, "other")
  }

  func testTerminalMovePreservesExactSessionAcrossConversationOwners() throws {
    let store = storeWithTerminalTask()
    defer { store.workspace.terminals.shutdown() }
    store.newTerminalTab(in: .bottom)
    let source = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let terminalID = try XCTUnwrap(source.terminalID)
    let session = try XCTUnwrap(store.terminalSession(terminalID))

    let migrated = store.moveWorkspaceTab(source.id, toOwner: "other")

    XCTAssertEqual(migrated, source.id)
    XCTAssertEqual(store.workspaceTabs, [.terminal(terminalID, owner: "other")])
    XCTAssertTrue(store.terminalSession(terminalID) === session)
    XCTAssertEqual(store.terminalScope(for: try XCTUnwrap(store.workspaceTabs.first))?.conversation, "other")
  }

  func testWorkspaceLayoutCommandsHideTabsToggleFullViewAndSwapPanes() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let source = try XCTUnwrap(store.activeWorkspaceContentTab)

    store.executeCommand("workspace-tabs")
    XCTAssertFalse(store.showingWorkspaceTabs)
    XCTAssertEqual(store.activeWorkspaceContentTab, source)
    store.executeCommand("workspace-tabs")
    XCTAssertTrue(store.showingWorkspaceTabs)

    store.executeCommand("workspace-view")
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, source)
    XCTAssertTrue(store.showingInspector)
    XCTAssertEqual(store.workspaceContentPaneSide, .right)

    store.executeCommand("workspace-swap-panes")
    XCTAssertEqual(store.workspaceContentPaneSide, .left)
    store.executeCommand("workspace-swap-panes")
    XCTAssertEqual(store.workspaceContentPaneSide, .right)

    store.executeCommand("workspace-view")
    XCTAssertEqual(store.activeWorkspaceContentTab, source)
    XCTAssertNil(store.activeRightWorkspaceContentTab)
  }

  func testNewTabLauncherActionsRespectTheRequestedPane() {
    let store = storeWithTask()

    store.openReviewTab(in: .right)

    XCTAssertEqual(store.activeRightWorkspaceContentTab, .review(owner: "task"))
    XCTAssertEqual(store.workspaceTabPlacement("review:task"), .right)
    XCTAssertTrue(store.showingInspector)
  }

  func testCloseOtherTabsIsScopedToTheCurrentPanel() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let left = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(in: .right)
    let right = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    store.openReviewTab()

    store.closeOtherWorkspaceTabs(keeping: right.id)
    XCTAssertTrue(store.visibleWorkspaceContentTabs.contains(left))
    XCTAssertTrue(store.visibleWorkspaceContentTabs.contains(.review(owner: "task")))
    XCTAssertTrue(store.visibleWorkspaceContentTabs.contains(right))
  }

  func testMultipleBottomTerminalsKeepExactSessionsAcrossEveryPlacement() throws {
    let store = storeWithTerminalTask()
    defer { store.workspace.terminals.shutdown() }

    store.newTerminalTab()
    let firstTab = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let firstID = try XCTUnwrap(firstTab.terminalID)
    let first = try XCTUnwrap(store.terminalSession(firstID))
    store.newTerminalTab()
    let secondTab = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let secondID = try XCTUnwrap(secondTab.terminalID)
    let second = try XCTUnwrap(store.terminalSession(secondID))

    XCTAssertNotEqual(firstID, secondID)
    XCTAssertFalse(first === second)
    store.activateWorkspaceTab(firstTab.id)
    XCTAssertEqual(store.activeBottomWorkspaceContentTab, firstTab)

    for placement in [WorkspaceTabPlacement.left, .right, .detached, .bottom] {
      store.moveWorkspaceTab(firstTab.id, to: placement)
      XCTAssertEqual(store.workspaceTabPlacement(firstTab.id), placement)
      XCTAssertTrue(store.terminalSession(firstID) === first)
      store.focusTerminal(firstID)
      let request = try XCTUnwrap(store.terminalFocusRequest)
      XCTAssertEqual(requestedSession(store), firstID)
      XCTAssertTrue(store.canFocusTerminal(request))
    }
    XCTAssertTrue(store.terminalSession(secondID) === second)
  }

  func testTerminalCloseAndRestartAffectOnlyTheSelectedSession() throws {
    let store = storeWithTerminalTask()
    defer { store.workspace.terminals.shutdown() }
    store.newTerminalTab()
    let firstTab = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let firstID = try XCTUnwrap(firstTab.terminalID)
    let first = try XCTUnwrap(store.terminalSession(firstID))
    store.newTerminalTab()
    let secondTab = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let secondID = try XCTUnwrap(secondTab.terminalID)
    let second = try XCTUnwrap(store.terminalSession(secondID))

    store.closeWorkspaceTab(firstTab.id)
    XCTAssertEqual(first.status, .stopped)
    XCTAssertNil(store.terminalSession(firstID))
    XCTAssertTrue(store.terminalSession(secondID) === second)
    XCTAssertEqual(second.status, .running)

    store.moveWorkspaceTab(secondTab.id, to: .right)
    let replacement = try XCTUnwrap(store.restartTerminalTab(secondID))
    XCTAssertEqual(second.status, .stopped)
    XCTAssertEqual(replacement.id, secondID, "Restart replaces the shell, not the tab identity")
    XCTAssertFalse(replacement === second)
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.terminalID, replacement.id)
    XCTAssertEqual(store.workspaceTabPlacement("terminal:\(replacement.id.uuidString)"), .right)
  }

  func testOnlyTerminalTabsCanMoveToBottomPanel() throws {
    let store = storeWithTask()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab()
    let browser = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.openReviewTab()
    let review = try XCTUnwrap(store.activeWorkspaceContentTab)

    store.moveWorkspaceTab(browser.id, to: .bottom)
    store.moveWorkspaceTab(review.id, to: .bottom)

    XCTAssertEqual(store.workspaceTabPlacement(browser.id), .left)
    XCTAssertEqual(store.workspaceTabPlacement(review.id), .left)
    XCTAssertTrue(store.visibleWorkspaceContentTabs(in: .bottom).isEmpty)
  }

  func testDraftPromotionPreservesAllTerminalTabsAndPanelSelection() throws {
    let store = WorkspaceStore()
    let root = GitBranchService.canonicalRoot(URL(fileURLWithPath: "/tmp"))
    store.project = root
    defer { store.workspace.terminals.shutdown() }
    let draftOwner = store.currentWorkspaceTabOwner
    let draftScope = try XCTUnwrap(store.terminalScope)
    store.newTerminalTab(in: .right)
    let right = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    store.newTerminalTab(in: .bottom)
    let bottom = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let rightSession = try XCTUnwrap(store.terminalSession(try XCTUnwrap(right.terminalID)))
    let bottomSession = try XCTUnwrap(store.terminalSession(try XCTUnwrap(bottom.terminalID)))
    store.pinWorkspaceTab(bottom.id)

    store.library.tasks = [
      .init(id: "created", project: root.path, title: "Created", runIDs: ["run"])
    ]
    store.selection = "run"
    let taskScope = try XCTUnwrap(store.terminalScope)
    store.workspace.terminals.adopt(from: draftScope, to: taskScope)
    store.moveWorkspaceTabs(from: draftOwner, to: "created")

    XCTAssertEqual(store.visibleWorkspaceContentTabs.count, 2)
    XCTAssertTrue(store.visibleWorkspaceContentTabs.allSatisfy { $0.owner == "created" })
    XCTAssertEqual(store.activeRightWorkspaceContentTab?.terminalID, right.terminalID)
    XCTAssertEqual(store.activeBottomWorkspaceContentTab?.terminalID, bottom.terminalID)
    XCTAssertTrue(store.terminalSession(try XCTUnwrap(right.terminalID)) === rightSession)
    XCTAssertTrue(store.terminalSession(try XCTUnwrap(bottom.terminalID)) === bottomSession)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.owner, "created")
  }

  private func requestedSession(_ store: WorkspaceStore) -> UUID? {
    store.terminalFocusRequest?.sessionID
  }
}
