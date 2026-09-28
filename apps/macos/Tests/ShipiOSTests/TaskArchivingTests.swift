import XCTest
@testable import ShipiOS

@MainActor final class TaskArchivingTests: XCTestCase {
  private func store() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-archive-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = ["current", "target", "other"].map {
      .init(id: $0, project: "", title: $0, runIDs: [$0])
    }
    store.selectTask(store.library.tasks[0])
    store.draft = "preserve current draft"
    return store
  }

  private func running(_ id: String) -> AgentRun {
    .init(id: id, kind: "chat", project: "", status: "running",
      createdAt: 1, updatedAt: 2, request: .null, result: nil)
  }

  func testOrdinarySidebarArchivesIdleTargetWithoutActivityOrSelection() async throws {
    let store = await store()
    XCTAssertFalse(store.showingActivity)
    XCTAssertTrue(store.canArchiveTask("target"))
    await store.archiveTask("target")
    XCTAssertEqual(store.library.tasks.filter(\.archived).map(\.id), ["target"])
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "preserve current draft")
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      .tasks.filter(\.archived).map(\.id), ["target"])
    await store.shutdown()
  }

  func testActiveArchiveCommandCapturesSelectedIdentityAndCancelPreservesWork() async throws {
    let store = await store()
    store.library.chatRuns = [running("current")]
    XCTAssertTrue(store.commandEnabled("archive"))
    XCTAssertEqual(store.shortcuts.binding("archive"), ShortcutBinding("⌘⇧A"))
    store.executeCommand("archive")
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while store.activityArchiveRequest == nil {
      guard ContinuousClock.now < deadline else { XCTFail("Archive command did not request confirmation"); return }
      await Task.yield()
    }
    let request = try XCTUnwrap(store.archiveConfirmation())
    XCTAssertEqual(request.taskIDs, ["current"])
    XCTAssertTrue(store.hasSettingsConfirmation)
    XCTAssertFalse(store.commandEnabled("archive"))
    store.dismissTaskArchive(requestID: request.id)
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertEqual(store.activeRun(taskID: "current")?.id, "current")
    XCTAssertFalse(store.library.tasks[0].archived)
    XCTAssertEqual(store.draft, "preserve current draft")
    await store.shutdown()
  }

  func testTaskWindowConfirmationDoesNotAppearOrExecuteInMainOrAnotherWindow() async throws {
    let store = await store()
    store.library.chatRuns = [running("target")]
    store.presentedOverlay = .imagePreview
    await store.archiveTask("target", inWindow: "window-a")
    let request = try XCTUnwrap(store.archiveConfirmation(inWindow: "window-a"))
    XCTAssertNil(store.archiveConfirmation())
    XCTAssertNil(store.archiveConfirmation(inWindow: "window-b"))
    XCTAssertFalse(store.hasSettingsConfirmation, "Main window does not own this task window dialog")
    XCTAssertEqual(request.taskIDs, ["target"])
    await store.confirmTaskArchive()
    await store.confirmTaskArchive(inWindow: "window-b")
    store.dismissActivityArchive()
    store.dismissTaskArchive(inWindow: "window-b")
    XCTAssertEqual(store.activityArchiveRequest?.id, request.id)
    XCTAssertEqual(store.presentedOverlay, .imagePreview)
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "preserve current draft")
    store.presentedOverlay = nil
    XCTAssertTrue(store.commandEnabled("new"))
    store.dismissTaskArchive(inWindow: "window-a", requestID: request.id)
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertNotNil(store.activeRun(taskID: "target"))
    await store.shutdown()
  }

  func testStaleDialogCallbacksCannotConfirmOrDismissNewRequestInSameWindow() async throws {
    let store = await store()
    store.library.chatRuns = [running("target"), running("other")]
    await store.archiveTask("target", inWindow: "window")
    let previous = try XCTUnwrap(store.activityArchiveRequest)
    store.dismissTaskArchive(inWindow: "window", requestID: previous.id)
    await store.archiveTask("other", inWindow: "window")
    let current = try XCTUnwrap(store.activityArchiveRequest)
    XCTAssertNotEqual(current.id, previous.id)
    store.dismissTaskArchive(inWindow: "window", requestID: previous.id)
    await store.confirmTaskArchive(inWindow: "window", requestID: previous.id)
    XCTAssertEqual(store.activityArchiveRequest?.id, current.id)
    XCTAssertTrue(store.library.tasks.allSatisfy { !$0.archived })
    XCTAssertNil(store.activityArchiveResult)
    await store.confirmTaskArchive(inWindow: "window", requestID: current.id)
    XCTAssertNil(store.activityArchiveRequest)
    XCTAssertEqual(store.activityArchiveResult?.failures.count, 1, "Unknown live request remains unarchived")
    XCTAssertTrue(store.library.tasks.allSatisfy { !$0.archived })
    XCTAssertNotNil(store.error)
    await store.shutdown()
  }

  func testOrdinaryArchiveWriteFailureKeepsDraftQueueAndTaskAndShowsError() async throws {
    let store = await store()
    let queued = QueuedMessage(taskID: "target", text: "later")
    store.library.queuedMessages = [queued]
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await store.archiveTask("target")
    XCTAssertTrue(store.library.tasks.allSatisfy { !$0.archived })
    XCTAssertEqual(store.library.queuedMessages, [queued])
    XCTAssertEqual(store.selectedTask?.id, "current")
    XCTAssertEqual(store.draft, "preserve current draft")
    XCTAssertNotNil(store.error)
    XCTAssertEqual(store.notices.items.first?.level, .error)
    await store.shutdown()
  }

  func testLocalAndModelStartsReserveOnlyArchiveTargetAndRejectArchivedTask() async {
    let store = await store()
    store.project = URL(fileURLWithPath: "/project")
    store.connected = true
    for index in store.library.tasks.indices { store.library.tasks[index].project = "/project" }
    store.selectTask(store.library.tasks[0])
    store.activityArchivingTaskIDs = ["current"]
    XCTAssertFalse(store.canStart)
    XCTAssertFalse(store.canStartChat(taskID: "current"))
    XCTAssertTrue(store.canStartChat(taskID: "other"))
    store.selectTask(store.library.tasks[2])
    XCTAssertTrue(store.canStart)
    store.activityArchivingTaskIDs = []
    store.library.tasks[2].archived = true
    XCTAssertFalse(store.canStart)
    XCTAssertFalse(store.canArchiveTask("other"))
    XCTAssertFalse(store.canArchiveTask("missing"))
    await store.shutdown()
  }

  func testPersistedEmptyTaskCanArchiveButTransientDraftCannot() async {
    let store = await store()
    store.library.tasks[1].runIDs = []
    XCTAssertTrue(store.canArchiveTask("target"))
    await store.archiveTask("target")
    XCTAssertTrue(store.library.tasks[1].archived)
    if let popout = store.createPopoutTask() {
      XCTAssertFalse(store.canArchiveTask(popout.id))
    } else { XCTFail("No transient draft") }
    await store.shutdown()
  }
}
