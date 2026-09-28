import XCTest
@testable import ShipiOS

@MainActor final class TaskDeletionTests: XCTestCase {
  private func makeStore() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-deletion-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = ["current", "target"].map {
      .init(id: $0, project: "", title: $0, runIDs: [])
    }
    store.selectTask(store.library.tasks[0])
    store.draft = "current draft"
    return store
  }

  func testRequestAndCancelPreserveWorkspaceAndActivity() async throws {
    let store = await makeStore()
    store.toggleActivity()
    let session = store.activitySession?.id
    store.requestTaskDeletion("target")
    let request = try XCTUnwrap(store.archiveDeletion)
    XCTAssertEqual(request.kind, .task)
    XCTAssertEqual(request.taskIDs, ["target"])
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "current draft")
    XCTAssertEqual(store.activitySession?.id, session)
    XCTAssertTrue(store.hasSettingsConfirmation)
    XCTAssertFalse(store.commandEnabled("new"))
    XCTAssertFalse(store.canArchiveTask("target", inWindow: "other-window"))
    store.requestTaskDeletion("current")
    XCTAssertEqual(store.archiveDeletion, request)
    store.dismissArchiveDeletion(requestID: request.id)
    XCTAssertNil(store.archiveDeletion)
    XCTAssertEqual(store.library.tasks.count, 2)
    await store.shutdown()
  }

  func testIdleDeletionRemovesOnlyTargetAndPersistsWithoutIntermediateArchive() async throws {
    let store = await makeStore()
    store.library.unreadTasks = ["target", "current"]
    store.library.drafts["target"] = "delete this"
    store.library.pinnedContentTabs = ["current", "target"].map {
      .init(id: "pin-" + $0, sourceTabID: "tab-" + $0, owner: $0,
        kind: .browser, title: $0, restoreURL: "https://example.com/" + $0)
    }
    store.library.sidebar.placement["c:pin-target"] = SidebarLayout.pinned
    store.library.sidebar.order[SidebarLayout.pinned] = ["c:pin-current", "c:pin-target"]
    store.library.queuedMessages = [.init(taskID: "target", text: "queued"),
      .init(taskID: "current", text: "keep")]
    store.requestTaskDeletion("target")
    await store.confirmArchiveDeletion()
    XCTAssertEqual(store.library.tasks.map(\.id), ["current"])
    XCTAssertNil(store.archiveDeletion)
    XCTAssertNil(store.archivedTaskDeletionError)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "current draft")
    XCTAssertNil(store.library.drafts["target"])
    XCTAssertEqual(store.library.pinnedContentTabs.map(\.owner), ["current"])
    XCTAssertNil(store.library.sidebar.placement["c:pin-target"])
    XCTAssertEqual(store.library.sidebar.order[SidebarLayout.pinned], ["c:pin-current"])
    XCTAssertEqual(store.library.queuedMessages.map(\.taskID), ["current"])
    XCTAssertEqual(store.library.unreadTasks, ["current"])
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.tasks.map(\.id), ["current"])
    XCTAssertFalse(saved.tasks[0].archived)
    await store.shutdown()
  }

  func testSaveFailureKeepsUnarchivedTaskAndFixedRequestForRetry() async throws {
    let store = await makeStore()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    store.requestTaskDeletion("target")
    let request = try XCTUnwrap(store.archiveDeletion)
    await store.confirmArchiveDeletion(requestID: request.id)
    XCTAssertEqual(store.archiveDeletion, request)
    XCTAssertNotNil(store.archivedTaskDeletionError)
    XCTAssertFalse(store.library.tasks[1].archived)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertFalse(store.deletingArchive)
    XCTAssertTrue(store.activityArchivingTaskIDs.isEmpty)
    store.library.tasks.append(.init(id: "later", project: "", title: "later", runIDs: []))
    try FileManager.default.removeItem(at: file)
    await store.confirmArchiveDeletion(requestID: request.id)
    XCTAssertEqual(store.library.tasks.map(\.id), ["current", "later"])
    XCTAssertNil(store.archiveDeletion)
    await store.shutdown()
  }

  func testOldConfirmationCannotCancelOrDeleteNewTarget() async throws {
    let store = await makeStore()
    store.requestTaskDeletion("target")
    let old = try XCTUnwrap(store.archiveDeletion)
    store.dismissArchiveDeletion(requestID: old.id)
    store.requestTaskDeletion("current")
    let current = try XCTUnwrap(store.archiveDeletion)
    store.dismissArchiveDeletion(requestID: old.id)
    await store.confirmArchiveDeletion(requestID: old.id)
    XCTAssertEqual(store.archiveDeletion, current)
    XCTAssertEqual(store.library.tasks.count, 2)
    store.dismissArchiveDeletion()
    await store.shutdown()
  }

  func testMissingRunningHandleFailsWithoutArchivingOrDeleting() async throws {
    let store = await makeStore()
    store.library.tasks[1].runIDs = ["running"]
    store.library.chatRuns = [.init(id: "running", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    store.requestTaskDeletion("target")
    let request = try XCTUnwrap(store.archiveDeletion)
    await store.confirmArchiveDeletion()
    XCTAssertEqual(store.archiveDeletion, request)
    XCTAssertNotNil(store.archivedTaskDeletionError)
    XCTAssertEqual(store.library.tasks.count, 2)
    XCTAssertFalse(store.library.tasks[1].archived)
    XCTAssertTrue(store.activityArchivingTaskIDs.isEmpty)
    store.dismissArchiveDeletion()
    await store.shutdown()
  }

  func testRemovedTargetDoesNotRetargetCurrentTask() async {
    let store = await makeStore()
    store.requestTaskDeletion("target")
    store.library.tasks.removeAll { $0.id == "target" }
    await store.confirmArchiveDeletion()
    XCTAssertNotNil(store.archivedTaskDeletionError)
    XCTAssertEqual(store.library.tasks.map(\.id), ["current"])
    store.dismissArchiveDeletion()
    await store.shutdown()
  }

  func testCurrentTaskDeletionClearsSelectionAndAuditCannotRestoreIt() async throws {
    let store = await makeStore()
    let run = AgentRun(id: "finished", kind: "build", project: "", status: "succeeded",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)
    store.library.tasks[0].runIDs = [run.id]
    store.library.chatRuns = [run]
    store.runs = [run]
    store.selection = run.id
    store.requestTaskDeletion("current")
    await store.confirmArchiveDeletion()
    XCTAssertNil(store.selectedTask)
    XCTAssertNil(store.selection)
    XCTAssertTrue(store.runs.isEmpty)
    var saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    saved.reconcile([run], project: "")
    XCTAssertFalse(saved.tasks.contains { $0.id == "current" || $0.runIDs.contains(run.id) })
    XCTAssertTrue(saved.deletedRunIDs.contains(run.id))
    await store.shutdown()
  }

  func testRequestGatesForEditorsReservationsAndUnloadedWorkspace() async {
    let store = await makeStore()
    store.renameProjectPath = "/project"
    XCTAssertFalse(store.canDeleteTaskFromMenu("target"))
    store.renameProjectPath = nil
    store.showingModelPicker = true
    store.requestTaskDeletion("target")
    XCTAssertNil(store.archiveDeletion)
    store.showingModelPicker = false
    store.activityArchivingTaskIDs = ["target"]
    XCTAssertFalse(store.canDeleteTaskFromMenu("target"))
    store.activityArchivingTaskIDs = []
    store.libraryLoaded = false
    store.requestArchiveDeletion(.task, ids: ["target"])
    XCTAssertNil(store.archiveDeletion)
    store.libraryLoaded = true
    await store.shutdown()
  }
}
