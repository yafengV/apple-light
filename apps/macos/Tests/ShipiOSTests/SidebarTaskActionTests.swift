import XCTest
@testable import ShipiOS

@MainActor final class SidebarTaskActionTests: XCTestCase {
  private func makeStore() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-actions-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = ["current", "target"].map {
      .init(id: $0, project: "", title: $0, runIDs: [$0])
    }
    store.selectTask(store.library.tasks[0])
    store.draft = "keep current draft"
    return store
  }

  func testTitleRenameUsesLatestSelectedTaskAndPreservesDraftAndActivity() async {
    let store = await makeStore()
    store.library.tasks[0].title = "latest title"
    store.toggleActivity()
    let session = store.activitySession?.id
    store.renameTaskFromRowTitle("current")
    XCTAssertEqual(store.renameTaskID, "current")
    XCTAssertEqual(store.renameDraft, "latest title")
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep current draft")
    XCTAssertEqual(store.activitySession?.id, session)
    store.renameTaskID = nil
    store.closeActivity()
    store.renameTaskFromRowTitle("current")
    XCTAssertEqual(store.renameTaskID, "current")
    store.renameTaskID = nil
    await store.shutdown()
  }

  func testTitleRenameCannotSelectOrConsumeUnreadOfAnotherTask() async {
    let store = await makeStore()
    store.library.unreadTasks = ["target"]
    store.renameTaskFromRowTitle("target")
    XCTAssertNil(store.renameTaskID)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertEqual(store.draft, "keep current draft")
    // The context menu still supports explicitly renaming a different row.
    store.renameTaskFromMenu("target")
    XCTAssertEqual(store.renameTaskID, "target")
    XCTAssertEqual(store.selectedTask?.id, "current")
    store.renameTaskID = nil
    await store.shutdown()
  }

  func testStaleTitleCannotRenameArchivedReservedOrRemovedTask() async {
    let store = await makeStore()
    store.activityArchivingTaskIDs = ["current"]
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.activityArchivingTaskIDs = []
    store.library.tasks[0].archived = true
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.library.tasks.removeAll { $0.id == "current" }
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    await store.shutdown()
  }

  func testOtherPagesAndModalEditorsBlockRowActions() async {
    let store = await makeStore()
    store.showProjects()
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.returnToWorkspace()
    store.renameProjectPath = "/project"
    store.renameTaskFromRowTitle("current")
    store.toggleTaskPinFromMenu("target")
    XCTAssertNil(store.renameTaskID)
    XCTAssertFalse(store.library.tasks[1].pinned)
    store.renameProjectPath = nil
    store.showingModelPicker = true
    XCTAssertNil(store.taskMenuTarget("target"))
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.showingModelPicker = false
    store.showingBranchPicker = true
    XCTAssertNil(store.taskMenuTarget("target"))
    store.showingBranchPicker = false
    store.showingCommands = true
    XCTAssertNil(store.taskMenuTarget("target"))
    store.showingCommands = false
    store.shortcutResetRequested = true
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.shortcutResetRequested = false
    await store.shutdown()
  }

  func testPeerActionsRemainAvailableWhenCrossProjectSelectionIsDisabled() async throws {
    let store = await makeStore()
    store.library.tasks[1].project = "/other/project"
    store.runs = [.init(id: "local", kind: "build", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    XCTAssertFalse(store.canSelectTask(store.library.tasks[1]))
    XCTAssertNotNil(store.taskMenuTarget("target"))
    store.toggleTaskPinFromMenu("target")
    XCTAssertTrue(store.library.tasks[1].pinned)
    XCTAssertTrue(store.canArchiveTask("target"))
    await store.archiveTask("target")
    XCTAssertTrue(store.library.tasks[1].archived)
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep current draft")
    XCTAssertEqual(store.runs[0].status, "running")
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertTrue(saved.tasks[1].pinned)
    XCTAssertTrue(saved.tasks[1].archived)
    await store.shutdown()
  }

  func testActiveRowArchiveKeepsFixedConfirmationAndCancelPreservesDraft() async {
    let store = await makeStore()
    store.library.chatRuns = [.init(id: "target", kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)]
    store.toggleTaskPinFromMenu("target")
    await store.archiveTask("target")
    XCTAssertEqual(store.archiveConfirmation()?.taskIDs, ["target"])
    store.renameTaskFromRowTitle("current")
    XCTAssertNil(store.renameTaskID)
    store.toggleTaskPinFromMenu("current")
    XCTAssertFalse(store.library.tasks[0].pinned)
    store.dismissTaskArchive()
    XCTAssertFalse(store.library.tasks[1].archived)
    XCTAssertTrue(store.library.tasks[1].pinned)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "keep current draft")
    await store.shutdown()
  }
}
