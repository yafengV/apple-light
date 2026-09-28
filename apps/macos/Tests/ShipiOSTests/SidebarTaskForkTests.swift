import XCTest
@testable import ShipiOS

@MainActor final class SidebarTaskForkTests: XCTestCase {
  private func makeStore() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-fork-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "current", project: "", title: "Current", runIDs: []),
      .init(id: "source", project: "", title: "Source", runIDs: ["first", "active"])]
    store.library.chatRuns = ["first", "active"].map {
      .init(id: $0, kind: "chat", project: "", status: $0 == "active" ? "running" : "succeeded",
        createdAt: 1, updatedAt: 2, request: .null, result: .object(["response": .string("reply-" + $0)]))
    }
    store.library.notes["first"] = "completed prompt"
    store.library.notes["active"] = "running prompt"
    store.selectTask(store.library.tasks[0])
    store.draft = "current draft"
    store.library.drafts["source"] = "/fork must remain"
    store.library.unreadTasks = ["source"]
    return store
  }

  func testOtherRowForkUsesLatestTitleAndCompletedHistoryWithoutSelectingSource() async throws {
    let store = await makeStore()
    store.library.tasks[1].title = "Latest source"
    store.toggleActivity()
    let session = store.activitySession?.id
    let created = await store.forkTaskFromMenu("source")
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(fork.title, "Latest source · 分叉")
    XCTAssertEqual(fork.runIDs.count, 1)
    XCTAssertEqual(fork.forkOrigin, .init(taskID: "source", runID: "first"))
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).map(\.content),
      ["completed prompt", "reply-first"])
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.library.drafts["current"], "current draft")
    XCTAssertEqual(store.library.drafts["source"], "/fork must remain")
    XCTAssertEqual(store.navigationBack.last?.run, "current")
    XCTAssertTrue(store.library.unreadTasks.contains("source"))
    XCTAssertEqual(store.activitySession?.id, session)
    XCTAssertEqual(store.activeRun(taskID: "source")?.id, "active")
    XCTAssertNil(store.taskMenuForkingID)
    await store.shutdown()
  }

  func testFailedWriteDoesNotCreateOrSelectForkAndAllowsRetry() async throws {
    let store = await makeStore()
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    store.toggleActivity()
    let failed = await store.forkTaskFromMenu("source")
    XCTAssertNil(failed)
    XCTAssertEqual(store.library.tasks.map(\.id), ["current", "source"])
    XCTAssertTrue(store.library.forkRuns.isEmpty)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "current draft")
    XCTAssertNotNil(store.activityError)
    XCTAssertNil(store.taskMenuForkingID)
    try FileManager.default.removeItem(at: file)
    let created = await store.forkTaskFromMenu("source")
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertNil(store.activityError)
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).tasks.first?.id, fork.id)
    await store.shutdown()
  }

  func testWindowForkRejectsReservedTargetButKeepsOtherTargetsAvailable() async throws {
    let store = await makeStore()
    let second = try store.forkTaskWindowConversation("source")
    store.requestTaskDeletion("source")
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    XCTAssertFalse(store.canForkTaskWindow("source"))
    XCTAssertThrowsError(try store.forkTaskWindowConversation("source"))
    XCTAssertTrue(store.canForkTaskWindow(second.id))
    store.dismissArchiveDeletion()
    store.activityArchiveRequest = .init(taskIDs: ["source"], scope: .task)
    XCTAssertFalse(store.canForkTaskWindow("source"))
    XCTAssertThrowsError(try store.forkTaskWindowConversation("source"))
    store.dismissTaskArchive()
    store.activityArchivingTaskIDs = ["source"]
    XCTAssertFalse(store.canForkTaskWindow("source"))
    store.activityArchivingTaskIDs = []
    await store.shutdown()
  }

  func testMenuGatesExcludeModalUnavailableAndAlreadyOpeningTasks() async {
    let store = await makeStore()
    XCTAssertTrue(store.canForkTaskFromMenu("source"))
    store.showingModelPicker = true
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    store.showingModelPicker = false
    store.taskMenuForkingID = "source"
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    store.taskMenuForkingID = nil
    store.library.tasks[1].archived = true
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    XCTAssertFalse(store.canForkTaskWindow("source"))
    store.library.tasks[1].archived = false
    store.library.tasks[1].sideChatParentID = "current"
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    store.library.tasks[1].sideChatParentID = nil
    store.restoringLibrary = true
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    store.restoringLibrary = false
    store.library.chatRuns.removeAll { $0.id == "first" }
    XCTAssertFalse(store.canForkTaskFromMenu("source"))
    await store.shutdown()
  }
}
