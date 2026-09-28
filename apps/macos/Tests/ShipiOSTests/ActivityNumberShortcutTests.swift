import XCTest
@testable import ShipiOS

@MainActor final class ActivityNumberShortcutTests: XCTestCase {
  private func makeStore() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-numbers-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root, agentExecutable: root.appendingPathComponent("missing-agent"))
    await store.restore()
    store.library.tasks = ["source", "first", "second", "recent", "pinned", "scheduled"].enumerated().map { index, id in
      var task = WorkspaceTask(id: id, project: "", title: id, runIDs: ["run-\(id)"])
      task.updatedAt = Date().addingTimeInterval(Double(index - 100))
      task.pinned = id == "pinned"
      return task
    }
    store.library.chatRuns = store.library.tasks.map {
      AgentRun(id: $0.runIDs[0], kind: "chat", project: "", status: "succeeded",
        createdAt: 1, updatedAt: 2, request: .null, result: nil)
    }
    store.selectTask(store.library.tasks[0])
    store.library.unreadTasks = ["first", "second", "pinned", "scheduled"]
    var automation = ShipAutomation()
    automation.name = "Daily"
    automation.prompt = "Check the project"
    automation.taskID = "scheduled"
    automation.lastRunID = "run-scheduled"
    store.automationPreferences.items = [automation]
    store.automationsLoaded = true
    store.toggleActivity()
    return store
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<300 {
      if predicate() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Activity navigation did not settle")
  }

  func testPrioritySlotsExcludeOtherSectionsAndNeverFallbackToRecent() async {
    let store = await makeStore()
    store.setActivityOption(\.showPinned, to: true)
    XCTAssertEqual(store.activityNumberedTasks.map(\.id), ["second", "first"])
    XCTAssertNotEqual(store.numberedSidebarTask(at: 1)?.id, store.library.visibleSidebarTasks[0].id)
    XCTAssertNil(store.numberedSidebarTask(at: 3))
    XCTAssertFalse(store.commandEnabled("focus-chat-3"))
    store.markActivityRead()
    XCTAssertEqual(store.activityNumberedTasks.map(\.id), ["second", "first"])
    store.clearReadActivity()
    XCTAssertTrue(store.activityNumberedTasks.isEmpty)
    XCTAssertFalse(store.commandEnabled("focus-chat-1"))
    XCTAssertFalse(store.activitySections().flatMap(\.items).isEmpty)
    await store.shutdown()
  }

  func testHiddenPriorityUsesPinnedThenRecentVisibleOrderAndFiltersScheduled() async {
    let store = await makeStore()
    store.setActivityOption(\.showPinned, to: true)
    store.setActivityOption(\.showPriority, to: false)
    XCTAssertEqual(store.activityNumberedTasks.map(\.id), ["pinned", "recent", "second", "first", "source"])
    store.setActivityOption(\.showScheduled, to: true)
    XCTAssertEqual(store.activityNumberedTasks.map(\.id), ["pinned", "scheduled", "recent", "second", "first", "source"])
    XCTAssertEqual(Set(store.activityNumberedTasks.map(\.id)).count, 6)
    store.setActivityOption(\.showPinned, to: false)
    XCTAssertEqual(store.numberedSidebarTask(at: 1)?.id, "scheduled")
    await store.shutdown()
  }

  func testNineIsExactPositionNotLastAliasAndClosingRestoresOrdinarySidebar() async {
    let store = await makeStore()
    store.library.tasks = (1...11).map { index in
      var task = WorkspaceTask(id: "task-\(index)", project: "", title: "Task", runIDs: ["run-\(index)"])
      task.updatedAt = Date().addingTimeInterval(Double(index - 100))
      return task
    }
    store.library.unreadTasks = Set(store.library.tasks.map(\.id))
    store.closeActivity()
    store.toggleActivity()
    XCTAssertEqual(store.activityNumberedTasks.count, 9)
    XCTAssertEqual(store.numberedSidebarTask(at: 9)?.id, "task-3")
    XCTAssertNil(store.numberedSidebarTask(at: 10))
    store.library.tasks.removeAll { $0.id == "task-11" }
    XCTAssertEqual(store.numberedSidebarTask(at: 1)?.id, "task-10")
    store.closeActivity()
    XCTAssertEqual(store.numberedSidebarTask(at: 1)?.id, store.library.visibleSidebarTasks[0].id)
    await store.shutdown()
  }

  func testShortcutUsesActivityTargetReviewsAutomationAndPreservesDraftAndPanels() async throws {
    let store = await makeStore()
    store.draft = "source draft"
    store.showingTerminal = true
    store.showingInspector = true
    store.setActivityOption(\.showScheduled, to: true)
    try store.shortcuts.setNumberShortcutTarget(.sidebar)
    try store.shortcuts.set(ShortcutBinding("⌘⇧8"), for: "focus-chat-1")
    let sessionID = store.activitySession?.id
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘⇧8")))
    await waitUntil { store.selectedTask?.id == "scheduled" }
    XCTAssertFalse(store.library.unreadTasks.contains("scheduled"))
    XCTAssertEqual(store.automationPreferences.items[0].reviewedRunID, "run-scheduled")
    XCTAssertEqual(store.activitySession?.id, sessionID)
    XCTAssertTrue(store.showingTerminal)
    XCTAssertTrue(store.showingInspector)
    store.selectTask(try XCTUnwrap(store.library.tasks.first { $0.id == "source" }))
    XCTAssertEqual(store.draft, "source draft")
    await store.shutdown()
  }

  func testRecentCommandsKeepTheirIndependentSixMRUSlots() async {
    let store = await makeStore()
    store.library.unreadTasks = []
    store.library.recordTaskVisit("recent")
    let before = store.recentCommandTasks.map(\.id)
    XCTAssertEqual(before.first, "recent")
    XCTAssertNotEqual(store.numberedSidebarTask(at: 1)?.id, before.first)
    store.setActivityOption(\.showPriority, to: false)
    store.setActivityOption(\.showPinned, to: true)
    XCTAssertEqual(store.recentCommandTasks.map(\.id), before)
    XCTAssertEqual(store.shortcuts.binding("recent-chat-1"), ShortcutBinding("⌘⌥1"))
    store.executeCommand("recent-chat-1")
    XCTAssertEqual(store.selectedTask?.id, "recent")
    XCTAssertTrue(store.showingActivity)
    XCTAssertFalse(store.commandEnabled("recent-chat-7"))
    await store.shutdown()
  }

  func testCrossProjectFailureKeepsOriginalSelectionDraftAndUnread() async throws {
    let store = await makeStore()
    store.setActivityOption(\.showPinned, to: true)
    let project = store.dataRoot.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let index = try XCTUnwrap(store.library.tasks.firstIndex { $0.id == "second" })
    store.library.tasks[index].project = project.resolvingSymlinksInPath().standardizedFileURL.path
    store.draft = "preserve on failure"
    store.showingTerminal = true
    store.showingInspector = true
    let history = store.navigationBack
    let sessionID = store.activitySession?.id
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌃1")))
    await waitUntil { store.activityError != nil }
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "preserve on failure")
    XCTAssertTrue(store.library.unreadTasks.contains("second"))
    XCTAssertEqual(store.activitySession?.id, sessionID)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.navigationBack, history)
    XCTAssertTrue(store.showingTerminal)
    XCTAssertTrue(store.showingInspector)
    XCTAssertNil(store.activityOpeningTaskID)
    await store.shutdown()
  }

  func testUnselectablePositionDoesNotShiftFollowingSlots() async {
    let store = await makeStore()
    store.setActivityOption(\.showPinned, to: true)
    store.library.tasks[2].project = "/unavailable-project"
    store.runs = [AgentRun(id: "build", kind: "build", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    XCTAssertEqual(store.numberedSidebarTask(at: 1)?.id, "second")
    XCTAssertFalse(store.commandEnabled("focus-chat-1"))
    XCTAssertEqual(store.numberedSidebarTask(at: 2)?.id, "first")
    XCTAssertTrue(store.commandEnabled("focus-chat-2"))
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌃2")))
    await waitUntil { store.selectedTask?.id == "first" }
    await store.shutdown()
  }

  func testDeferredShortcutCannotOpenAfterSessionClosesOrTaskIsArchived() async throws {
    let store = await makeStore()
    let sessionID = try XCTUnwrap(store.activitySession?.id)
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌃1")))
    store.closeActivity()
    store.toggleActivity()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(store.selectedTask?.id, "source")
    await store.openActivityNumberedTask("second", sessionID: sessionID)
    XCTAssertEqual(store.selectedTask?.id, "source")
    let currentSession = try XCTUnwrap(store.activitySession?.id)
    store.library.tasks[2].archived = true
    await store.openActivityNumberedTask("second", sessionID: currentSession)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertTrue(store.library.unreadTasks.contains("second"))
    await store.shutdown()
  }

  func testDeferredTargetKeepsIdentityWhenEarlierPriorityItemDisappears() async throws {
    let store = await makeStore()
    let sessionID = try XCTUnwrap(store.activitySession?.id)
    store.setActivityOption(\.showScheduled, to: true)
    XCTAssertEqual(store.numberedSidebarTask(at: 2)?.id, "pinned")
    store.library.tasks[5].archived = true
    XCTAssertEqual(store.numberedSidebarTask(at: 2)?.id, "second")
    await store.openActivityNumberedTask("pinned", sessionID: sessionID)
    XCTAssertEqual(store.selectedTask?.id, "pinned")
    XCTAssertTrue(store.library.unreadTasks.contains("second"))
    await store.shutdown()
  }

  func testPendingOpenSettingsAndConfirmationDisableSidebarShortcuts() async throws {
    let store = await makeStore()
    store.activityOpeningTaskID = "second"
    XCTAssertFalse(store.commandEnabled("focus-chat-1"))
    let opened = await store.openActivityTask("first")
    XCTAssertFalse(opened)
    XCTAssertEqual(store.selectedTask?.id, "source")
    store.activityOpeningTaskID = nil
    let sessionID = try XCTUnwrap(store.activitySession?.id)
    store.openSettings(.shortcuts)
    XCTAssertFalse(store.handleWorkspaceShortcut(ShortcutBinding("⌃1")))
    await store.openActivityNumberedTask("second", sessionID: sessionID)
    store.closeSettings()
    store.shortcutResetRequested = true
    await store.openActivityNumberedTask("second", sessionID: sessionID)
    XCTAssertEqual(store.selectedTask?.id, "source")
    store.shortcutResetRequested = false
    await store.shutdown()
  }
}
