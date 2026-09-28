import XCTest
@testable import ShipiOS

@MainActor final class ActivityArchiveTests: XCTestCase {
  private func store() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-archive-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    return store
  }
  private func task(_ id: String) -> WorkspaceTask {
    var task = WorkspaceTask(id: id, project: "", title: id, runIDs: [id])
    task.updatedAt = Date()
    return task
  }

  func testConfirmationKeepsFixedPriorityScopeAndPreservesRecentPinnedAndScheduled() async throws {
    let store = await store()
    store.library.tasks = ["target", "recent", "pinned", "scheduled"].map(task)
    store.library.tasks[2].pinned = true
    var automation = ShipAutomation()
    automation.taskID = "scheduled"
    store.automationPreferences.items = [automation]
    store.library.unreadTasks = ["target", "pinned", "scheduled"]
    store.setActivityOption(\.showPinned, to: true)
    store.selectTask(store.library.tasks[0])
    store.setTaskUnread("target", unread: true)
    store.toggleActivity()
    XCTAssertEqual(store.activityArchiveEligibleIDs, ["target"])
    store.requestActivityArchive()
    XCTAssertEqual(store.activityArchiveRequest?.taskIDs, ["target"])
    XCTAssertTrue(store.hasSettingsConfirmation)
    XCTAssertFalse(store.commandEnabled("new"))
    store.library.tasks.append(task("arrived"))
    store.library.unreadTasks.insert("arrived")
    store.requestActivityArchive()
    XCTAssertEqual(store.activityArchiveRequest?.taskIDs, ["target"])
    await store.confirmActivityArchive()
    XCTAssertEqual(store.activityArchiveResult, .init(archivedIDs: ["target"]))
    XCTAssertEqual(store.library.tasks.filter(\.archived).map(\.id), ["target"])
    XCTAssertNil(store.selectedTask)
    XCTAssertTrue(store.showingActivity)
    XCTAssertFalse(store.hasSettingsConfirmation)
    XCTAssertFalse(store.canStartChat(taskID: "target"))
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      .tasks.filter(\.archived).map(\.id), ["target"])
    XCTAssertEqual(store.notices.items.first?.level, .success)
    XCTAssertTrue(store.restoreArchivedTask("target"))
    XCTAssertTrue(store.canStartChat(taskID: "target"))
    await store.shutdown()
  }

  func testCancelAndBusyCannotChangeConfirmationOrArchiveTasks() async {
    let store = await store()
    store.library.tasks = [task("one")]
    store.library.unreadTasks = ["one"]
    store.toggleActivity()
    store.requestActivityArchive()
    store.dismissActivityArchive()
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertFalse(store.library.tasks[0].archived)
    store.requestActivityArchive()
    let id = store.activityArchiveRequest?.id
    store.archivingActivity = true
    store.dismissActivityArchive()
    await store.confirmActivityArchive()
    XCTAssertEqual(store.activityArchiveRequest?.id, id)
    XCTAssertFalse(store.library.tasks[0].archived)
    store.archivingActivity = false
    await store.confirmActivityArchive()
    XCTAssertTrue(store.library.tasks[0].archived)
    await store.shutdown()
  }

  func testPartialFailureKeepsUnknownLiveRunAndArchivesOtherTargets() async {
    let store = await store()
    store.library.tasks = [task("unknown"), task("idle")]
    store.library.chatRuns = [.init(id: "unknown", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    store.library.unreadTasks = ["idle"]
    store.toggleActivity()
    store.requestActivityArchive()
    XCTAssertTrue(store.activityArchiveNeedsStop)
    await store.confirmActivityArchive()
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, ["idle"])
    XCTAssertEqual(Set(store.activityArchiveResult?.failures.keys.map { $0 } ?? []), ["unknown"])
    XCTAssertFalse(store.library.tasks[0].archived)
    XCTAssertNotNil(store.activeRun(taskID: "unknown"))
    XCTAssertTrue(store.activityError?.contains("unknown") == true)
    XCTAssertEqual(store.notices.items.first?.level, .error)
    XCTAssertEqual(store.notices.items.first?.title, "已归档 1 个优先任务；1 个无法归档")
    XCTAssertTrue(store.activityArchivingTaskIDs.isEmpty)
    XCTAssertFalse(store.archivingActivity)
    await store.shutdown()
  }

  func testSaveFailurePreservesTasksUnreadAndQueue() async throws {
    let store = await store()
    store.library.tasks = [task("one"), task("two")]
    store.library.unreadTasks = ["one", "two"]
    let queue = QueuedMessage(taskID: "one", text: "Later")
    store.library.queuedMessages = [queue]
    store.toggleActivity()
    store.requestActivityArchive()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await store.confirmActivityArchive()
    XCTAssertTrue(store.library.tasks.allSatisfy { !$0.archived })
    XCTAssertEqual(store.library.unreadTasks, ["one", "two"])
    XCTAssertEqual(store.library.queuedMessages, [queue])
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, [])
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 2)
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertTrue(store.showingActivity)
    await store.shutdown()
  }

  func testDisconnectedLocalRunIsPreservedAndOnlyReservedModelTasksAreBlocked() async {
    let store = await store()
    store.library.tasks = [task("local"), task("idle"), task("other")]
    store.runs = [.init(id: "local", kind: "build", project: "/missing", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    store.library.unreadTasks = ["idle"]
    store.activityArchivingTaskIDs = ["idle"]
    XCTAssertFalse(store.canStartChat(taskID: "idle"))
    XCTAssertTrue(store.canStartChat(taskID: "other"))
    store.activityArchivingTaskIDs = []
    store.toggleActivity()
    store.requestActivityArchive()
    await store.confirmActivityArchive()
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, ["idle"])
    XCTAssertTrue(store.activityArchiveResult?.failures["local"]?.contains("未连接") == true)
    XCTAssertFalse(store.library.tasks.first(where: { $0.id == "local" })?.archived ?? true)
    XCTAssertFalse(store.library.tasks.first(where: { $0.id == "other" })?.archived ?? true)
    await store.shutdown()
  }

  func testRemovedTaskFailsAndNewTaskIsNotAddedToArchiveRequest() async {
    let store = await store()
    store.library.tasks = [task("gone"), task("kept")]
    store.library.unreadTasks = ["gone", "kept"]
    store.toggleActivity()
    store.requestActivityArchive()
    store.library.tasks.removeAll { $0.id == "gone" }
    store.library.tasks.append(task("new"))
    store.library.unreadTasks.insert("new")
    await store.confirmActivityArchive()
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, ["kept"])
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 1)
    XCTAssertEqual(store.library.tasks.filter(\.archived).map(\.id), ["kept"])
    XCTAssertFalse(store.library.tasks.last?.archived ?? true)
    await store.shutdown()
  }
}
