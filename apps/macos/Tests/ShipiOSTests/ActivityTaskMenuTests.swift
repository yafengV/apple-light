import XCTest
@testable import ShipiOS

@MainActor final class ActivityTaskMenuTests: XCTestCase {
  private func store() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("activity-menu-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = ["current", "target", "other"].map {
      var task = WorkspaceTask(id: $0, project: "", title: $0, runIDs: [$0])
      task.updatedAt = Date()
      return task
    }
    store.selectTask(store.library.tasks[0])
    store.draft = "keep my draft"
    store.toggleActivity()
    return store
  }

  func testRowPinReadAndRenamePreserveCurrentTaskAndPersistLatestState() async throws {
    let store = await store()
    store.setActivityOption(\.showPinned, to: true)
    store.toggleTaskReadFromMenu("target")
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["target"])
    store.toggleTaskPinFromMenu("target")
    XCTAssertEqual(store.activitySections().first(where: { $0.id == .pinned })?.items.map(\.id), ["target"])
    XCTAssertTrue(store.activityPriorityEntries.isEmpty)
    store.toggleTaskPinFromMenu("target")
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["target"])
    store.toggleTaskReadFromMenu("target")
    XCTAssertEqual(store.activityPriorityEntries.map(\.id), ["target"], "Read tasks stay until Clear read")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertFalse(saved.tasks[1].pinned)
    XCTAssertFalse(saved.unreadTasks.contains("target"))
    store.library.tasks[1].title = "latest title"
    store.renameTaskFromMenu("target")
    XCTAssertEqual(store.renameTaskID, "target")
    XCTAssertEqual(store.renameDraft, "latest title")
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep my draft")
    XCTAssertTrue(store.showingActivity)
    store.renameTaskID = nil
    await store.shutdown()
  }

  func testNewWindowTargetsRowWithoutSelectingReadingOrLosingLocalWork() async throws {
    let store = await store()
    store.library.tasks[1].project = "/other/project"
    store.library.unreadTasks = ["target"]
    store.runs = [.init(id: "local", kind: "build", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    XCTAssertFalse(store.canSelectTask(store.library.tasks[1]))
    XCTAssertTrue(store.openTaskInNewWindow("target"))
    let first = try XCTUnwrap(store.taskWindowOpenRequest)
    XCTAssertEqual(first.taskID, "target")
    XCTAssertEqual(first.dataRoot, TaskWindowRoute.workspacePath(store.dataRoot))
    XCTAssertTrue(store.openTaskInNewWindow("target"))
    XCTAssertNotEqual(first.id, store.taskWindowOpenRequest?.id)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep my draft")
    XCTAssertEqual(store.library.unreadTasks, ["target"])
    XCTAssertTrue(store.showingActivity)
    await store.shutdown()
  }

  func testStaleRemovedArchivedAndReservedTargetsCannotOpenOrMutate() async {
    let store = await store()
    store.activityArchivingTaskIDs = ["target"]
    XCTAssertNil(store.taskMenuTarget("target"))
    store.toggleTaskPinFromMenu("target")
    store.toggleTaskReadFromMenu("target")
    XCTAssertFalse(store.openTaskInNewWindow("target"))
    XCTAssertFalse(store.library.tasks[1].pinned)
    XCTAssertFalse(store.library.unreadTasks.contains("target"))
    XCTAssertTrue(store.openTaskInNewWindow("other"))
    let existing = store.taskWindowOpenRequest
    store.activityArchivingTaskIDs = []
    store.library.tasks.removeAll { $0.id == "target" }
    store.renameTaskFromMenu("target")
    store.toggleTaskPinFromMenu("target")
    XCTAssertFalse(store.openTaskInNewWindow("target"))
    XCTAssertNil(store.renameTaskID)
    store.library.tasks[1].archived = true
    XCTAssertFalse(store.openTaskInNewWindow("other"))
    XCTAssertEqual(store.taskWindowOpenRequest, existing)
    store.openSettings(.general)
    store.requestActivityArchive()
    // No confirmation without a visible priority target.
    XCTAssertNil(store.activityArchiveRequest)
    await store.shutdown()
  }

  func testFailedMenuWritesPreservePinUnreadAndCurrentDraft() async throws {
    let store = await store()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    store.toggleTaskPinFromMenu("target")
    XCTAssertFalse(store.library.tasks[1].pinned)
    XCTAssertNotNil(store.activityError)
    store.toggleTaskReadFromMenu("target")
    XCTAssertFalse(store.library.unreadTasks.contains("target"))
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep my draft")
    await store.shutdown()
  }

  func testCopyContentUsesRowScopeAndStoredCrossProjectRunsWithoutSelecting() async {
    let store = await store()
    store.library.tasks[1].project = "/other/project"
    store.library.notes["target"] = "target prompt"
    store.library.chatRuns = [.init(id: "target", kind: "chat", project: "/other/project", status: "succeeded",
      createdAt: 1, updatedAt: 2, request: .null, result: .object(["response": .string("target answer")]))]
    let text = store.taskShareText(store.library.tasks[1])
    XCTAssertTrue(text.contains("target prompt"))
    XCTAssertTrue(text.contains("target answer"))
    XCTAssertFalse(text.contains("keep my draft"))
    XCTAssertEqual(store.taskMenuWorkingDirectory(store.library.tasks[1]), "/other/project")
    XCTAssertNil(store.taskMenuWorkingDirectory(store.library.tasks[2]))
    store.library.projectlessTaskDirectories["other"] = "/private/output"
    XCTAssertEqual(store.taskMenuWorkingDirectory(store.library.tasks[2]), "/private/output")
    XCTAssertEqual(store.selectedTask?.id, "current")
    await store.shutdown()
  }

  func testIdleRecentRowArchivesOnlyItselfWithoutConfirmationOrSelection() async throws {
    let store = await store()
    XCTAssertTrue(store.activityPriorityEntries.isEmpty)
    XCTAssertTrue(store.canArchiveActivityTask("target"))
    await store.archiveActivityTask("target")
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertEqual(store.activityArchiveResult?.archivedIDs, ["target"])
    XCTAssertEqual(store.library.tasks.filter(\.archived).map(\.id), ["target"])
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep my draft")
    XCTAssertTrue(store.showingActivity)
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      .tasks.filter(\.archived).map(\.id), ["target"])
    await store.shutdown()
  }

  func testRunningRowConfirmsFixedIdentityAndCancelPreservesIt() async {
    let store = await store()
    store.library.chatRuns = [.init(id: "target", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    await store.archiveActivityTask("target")
    XCTAssertEqual(store.activityArchiveRequest?.scope, .task)
    XCTAssertEqual(store.activityArchiveRequest?.taskIDs, ["target"])
    await store.archiveActivityTask("other")
    XCTAssertEqual(store.activityArchiveRequest?.taskIDs, ["target"])
    store.dismissActivityArchive()
    XCTAssertFalse(store.library.tasks[1].archived)
    await store.archiveActivityTask("target")
    await store.confirmActivityArchive()
    XCTAssertFalse(store.library.tasks[1].archived, "Unknown request cannot be safely stopped")
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 1)
    XCTAssertEqual(store.selectedTask?.id, "current")
    await store.shutdown()
  }

  func testRowReadReviewsOnlyItsAutomationAfterSuccessfulSave() async throws {
    let store = await store()
    var first = ShipAutomation()
    first.name = "First"
    first.prompt = "Check first project"
    first.taskID = "target"
    first.lastRunID = "target"
    var second = ShipAutomation()
    second.name = "Second"
    second.prompt = "Check second project"
    second.taskID = "other"
    second.lastRunID = "other"
    store.automationPreferences.items = [first, second]
    store.automationsLoaded = true
    store.library.unreadTasks = ["target", "other"]
    store.toggleTaskReadFromMenu("target")
    XCTAssertEqual(store.automationPreferences.items[0].reviewedRunID, "target")
    XCTAssertNil(store.automationPreferences.items[1].reviewedRunID)
    XCTAssertEqual(store.library.unreadTasks, ["other"])
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    store.toggleTaskReadFromMenu("other")
    XCTAssertNil(store.automationPreferences.items[1].reviewedRunID)
    XCTAssertEqual(store.library.unreadTasks, ["other"])
    await store.shutdown()
  }
}
