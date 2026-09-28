import XCTest
@testable import ShipiOS

@MainActor final class ActivityNavigationTests: XCTestCase {
  private func store(withMissingAgent: Bool = false) async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: withMissingAgent ? root.appendingPathComponent("missing-agent") : nil)
    await store.restore()
    return store
  }

  private func run(_ id: String, status: String) -> AgentRun {
    AgentRun(id: id, kind: "chat", project: "", status: status,
      createdAt: 1, updatedAt: 2, request: .null, result: nil)
  }

  func testActivityOrdersPendingRunningAndUnreadWithoutArchivedTasks() async {
    let store = await store()
    store.library.tasks = ["unread", "running", "pending", "archived"].map {
      .init(id: $0, project: "", title: $0, runIDs: [$0])
    }
    store.library.tasks[3].archived = true
    store.runs = [run("unread", status: "succeeded"), run("running", status: "running"),
      run("pending", status: "running"), run("archived", status: "succeeded")]
    store.library.unreadTasks = ["unread", "pending", "archived"]
    let execution = MCPToolExecution(callID: "call", serverID: UUID(), serverName: "server",
      toolName: "tool", arguments: "{}")
    store.mcpPendingApprovals[execution.id] = MCPApprovalContext(runID: "pending", execution: execution)

    let items = store.activityEntries
    XCTAssertEqual(items.map(\.id), ["pending", "running", "unread"])
    XCTAssertEqual(items.map(\.statusTitle), ["等待工具批准", "正在运行", "未读活动"])
    XCTAssertEqual(store.activityBadgeCount, 2)
    store.toggleActivity()
    store.markActivityRead()
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["pending", "running", "unread"])
    store.clearReadActivity()
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["pending", "running"])
    XCTAssertEqual(store.activityBadgeCount, 1)
    await store.shutdown()
  }

  func testActivityNavigationKeepsSettingsReturnAndOpeningConsumesUnread() async {
    let store = await store()
    store.library.tasks = [.init(id: "target", project: "", title: "Target", runIDs: ["run"])]
    store.runs = [run("run", status: "succeeded")]
    store.library.unreadTasks = ["target"]
    XCTAssertTrue(store.commandEnabled("activity"))
    XCTAssertEqual(store.shortcuts.binding("activity"), ShortcutBinding("⌘⌥U"))
    store.executeCommand("activity")
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertTrue(store.showingActivity)
    XCTAssertFalse(store.retainsStandalonePage)
    store.openSettings(.notifications)
    store.closeSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertTrue(store.showingActivity)
    let opened = await store.openActivityTask("target")
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.id, "target")
    XCTAssertFalse(store.library.unreadTasks.contains("target"))
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["target"])
    store.clearReadActivity()
    XCTAssertTrue(store.activityPriorityEntries.isEmpty)
    store.executeCommand("activity")
    XCTAssertFalse(store.showingActivity)
    store.executeCommand("activity")
    XCTAssertTrue(store.showingActivity)
    await store.shutdown()
  }

  func testFailedCrossProjectOpenReturnsToActivityWithoutConsumingUnread() async throws {
    let store = await store(withMissingAgent: true)
    let project = store.dataRoot.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let path = project.resolvingSymlinksInPath().standardizedFileURL.path
    store.library.tasks = [.init(id: "target", project: path, title: "Target", runIDs: ["run"])]
    store.library.unreadTasks = ["target"]
    store.showProjects()
    store.toggleActivity()
    let opened = await store.openActivityTask("target")
    XCTAssertFalse(opened)
    XCTAssertEqual(store.destination, .projects)
    XCTAssertTrue(store.showingActivity)
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertNotNil(store.activityError)
    await store.shutdown()
  }

  func testPinnedAndScheduledFiltersIncludeReadTasksAndOpeningReviewsAutomation() async {
    let store = await store()
    var pinned = WorkspaceTask(id: "pinned", project: "", title: "Pinned", runIDs: ["pinned-run"])
    pinned.pinned = true
    store.library.tasks = [pinned,
      .init(id: "scheduled", project: "", title: "Scheduled", runIDs: ["scheduled-run"])]
    store.runs = [run("pinned-run", status: "succeeded"),
      run("scheduled-run", status: "succeeded")]
    var automation = ShipAutomation()
    automation.name = "Daily"
    automation.prompt = "Check the project"
    automation.taskID = "scheduled"
    automation.lastRunID = "scheduled-run"
    store.automationPreferences.items = [automation]
    store.automationsLoaded = true

    XCTAssertEqual(store.activityEntries.map(\.id), ["pinned", "scheduled"])
    XCTAssertEqual(store.activityEntries.map(\.statusTitle), ["已置顶", "计划任务"])
    XCTAssertEqual(store.activityBadgeCount, 0)

    store.toggleActivity()
    let opened = await store.openActivityTask("scheduled")
    XCTAssertTrue(opened)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.automationPreferences.items.first?.reviewedRunID, "scheduled-run")
    await store.shutdown()
  }

  func testActivitySidebarKeepsConversationDraftPanelsAndSettingsReturn() async {
    let store = await store()
    store.library.tasks = [.init(id: "current", project: "", title: "Current", runIDs: ["run"])]
    store.runs = [run("run", status: "succeeded")]
    store.selectTask(store.library.tasks[0])
    store.draft = "继续编辑的草稿"
    store.showingTerminal = true
    store.showingInspector = true
    store.toggleActivity()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertFalse(store.retainsStandalonePage)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "继续编辑的草稿")
    XCTAssertTrue(store.showingTerminal)
    XCTAssertTrue(store.showingInspector)
    store.openSettings(.general)
    XCTAssertTrue(store.showingActivity)
    store.closeSettings()
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertTrue(store.showingActivity)
    await store.navigate(back: true)
    XCTAssertFalse(store.showingActivity)
    XCTAssertEqual(store.draft, "继续编辑的草稿")
    store.toggleActivity()
    store.showProjects()
    XCTAssertFalse(store.showingActivity)
    XCTAssertEqual(store.destination, .projects)
    await store.shutdown()
  }

  func testIndependentOptionsSeparatePinnedHideScheduledAndPersistDefaults() async throws {
    let store = await store()
    store.library.tasks = ["pinned", "scheduled", "other"].map {
      var task = WorkspaceTask(id: $0, project: "", title: $0, runIDs: [$0])
      task.updatedAt = Date()
      task.pinned = $0 == "pinned"
      return task
    }
    store.library.chatRuns = [run("pinned", status: "succeeded"), run("scheduled", status: "succeeded"),
      run("other", status: "succeeded")]
    var automation = ShipAutomation()
    automation.taskID = "scheduled"
    store.automationPreferences.items = [automation]
    store.library.unreadTasks = ["pinned", "scheduled", "other"]
    store.toggleActivity()
    XCTAssertEqual(Set(store.activityPriorityEntries.map(\.id)), ["pinned", "other"])
    store.setActivityOption(\.showPinned, to: true)
    store.setActivityOption(\.showScheduled, to: true)
    let sections = store.activitySections()
    XCTAssertEqual(sections.map(\.id), [.priority, .pinned])
    XCTAssertEqual(Set(sections[0].items.map(\.id)), ["scheduled", "other"])
    XCTAssertEqual(sections[1].items.map(\.id), ["pinned"])
    store.markActivityRead()
    XCTAssertEqual(store.library.unreadTasks, ["pinned"])
    store.setActivityOption(\.showPriority, to: false)
    XCTAssertFalse(store.activitySections().contains { $0.id == .priority })
    XCTAssertEqual(Set(store.activitySections().flatMap(\.items).map(\.id)), ["pinned", "scheduled", "other"])
    let decoded = try JSONDecoder().decode(WorkspaceLibrary.self, from:
      Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json")))
    XCTAssertEqual(decoded.activityPreferences, store.library.activityPreferences)
    store.restoreActivityDefaults()
    XCTAssertEqual(store.library.activityPreferences, .init())
    XCTAssertEqual(try JSONDecoder().decode(ActivityPreferences.self, from: Data("{}".utf8)), .init())
    await store.shutdown()
  }

  func testPriorityRetainsFinishedTasksUntilClearAndReaddsNewUnreadActivity() async {
    let store = await store()
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: ["run"])]
    store.library.tasks[0].updatedAt = Date().addingTimeInterval(-20 * 86400)
    store.library.chatRuns = [run("run", status: "running")]
    store.toggleActivity()
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["task"])
    store.library.chatRuns[0] = run("run", status: "succeeded")
    store.library.tasks[0].updatedAt = Date()
    XCTAssertFalse(store.activityPriorityEntries[0].needsAttention)
    store.clearReadActivity()
    XCTAssertTrue(store.activityPriorityEntries.isEmpty)
    XCTAssertEqual(store.activitySections().flatMap(\.items).map(\.id), ["task"])
    store.setTaskUnread("task", unread: true)
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["task"])
    store.closeActivity()
    store.toggleActivity()
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["task"])
    store.library.tasks[0].archived = true
    XCTAssertTrue(store.activityPriorityEntries.isEmpty)
    await store.shutdown()
  }

  func testRecentActivityHasSevenCalendarDaysAndStableDatesWithoutDuplicates() async {
    let store = await store()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.startOfDay(for: Date())
    store.library.tasks = [0, 1, 6, 7].map { day in
      var task = WorkspaceTask(id: "day\(day)", project: "", title: "Day \(day)", runIDs: ["r\(day)"])
      task.updatedAt = calendar.date(byAdding: .day, value: -day, to: start)
      return task
    }
    store.library.tasks[3].pinned = true
    store.toggleActivity()
    let before = store.activitySections(calendar: calendar)
    XCTAssertEqual(before.flatMap(\.items).map(\.id), ["day0", "day1", "day6"])
    store.library.tasks[2].updatedAt = Date()
    XCTAssertEqual(store.activitySections(calendar: calendar).map(\.id), before.map(\.id))
    store.setActivityOption(\.showPinned, to: true)
    let ids = store.activitySections(calendar: calendar).flatMap(\.items).map(\.id)
    XCTAssertEqual(ids, ["day7", "day0", "day1", "day6"])
    XCTAssertEqual(Set(ids).count, ids.count)
    await store.shutdown()
  }

  func testFailedActivityWritesKeepOptionsAndUnreadAndShowLocalError() async throws {
    let store = await store()
    store.library.tasks = [.init(id: "unread", project: "", title: "Unread", runIDs: ["run"])]
    store.library.unreadTasks = ["unread"]
    store.toggleActivity()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    store.setActivityOption(\.showPinned, to: true)
    XCTAssertFalse(store.library.activityPreferences.showPinned)
    XCTAssertNotNil(store.activityError)
    store.markActivityRead()
    XCTAssertEqual(store.library.unreadTasks, ["unread"])
    XCTAssertNotNil(store.activityError)
    XCTAssertTrue(store.showingActivity)
    await store.shutdown()
  }

}
