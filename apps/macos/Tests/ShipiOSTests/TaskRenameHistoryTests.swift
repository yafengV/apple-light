import XCTest
@testable import ShipiOS

@MainActor final class TaskRenameHistoryTests: XCTestCase {
  private func fixture() async throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.library.drafts = ["a": "Draft A", "b": "Draft B"]
    store.selectTask(store.library.tasks[0])
    return (store, root)
  }

  func testUndoRedoPersistNamesAndPreserveSelectedTaskAndDrafts() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = TaskRenameHistory()
    try history.rename(store: store, taskID: "b", title: "B2")
    try history.rename(store: store, taskID: "b", title: "B3")
    history.perform(redo: false, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "B2")
    history.perform(redo: false, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "B")
    history.perform(redo: true, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "B2")
    history.perform(redo: true, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "B3")
    XCTAssertEqual(store.selectedTask?.id, "a")
    XCTAssertEqual(store.library.drafts, ["a": "Draft A", "b": "Draft B"])
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(restored.library.tasks.first { $0.id == "b" }?.title, "B3")
    await store.shutdown(); await restored.shutdown()
  }

  func testFailedUndoCanBeRetriedWithoutConsumingHistory() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = TaskRenameHistory()
    try history.rename(store: store, taskID: "b", title: "Changed")
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    history.perform(redo: false, store: store)
    XCTAssertTrue(history.failed)
    XCTAssertTrue(history.canPerform(redo: false, store: store))
    XCTAssertFalse(history.canPerform(redo: true, store: store))
    XCTAssertEqual(store.library.tasks[1].title, "Changed")
    try FileManager.default.removeItem(at: file)
    history.perform(redo: false, store: store)
    XCTAssertFalse(history.failed)
    XCTAssertEqual(store.library.tasks[1].title, "B")
    XCTAssertTrue(history.canPerform(redo: true, store: store))
    await store.shutdown()
  }

  func testOtherWindowRenameAndDeletedTaskCannotBeOverwritten() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = TaskRenameHistory(), second = TaskRenameHistory()
    try first.rename(store: store, taskID: "b", title: "First")
    XCTAssertFalse(second.canPerform(redo: false, store: store))
    try second.rename(store: store, taskID: "b", title: "Second")
    XCTAssertFalse(first.canPerform(redo: false, store: store))
    first.perform(redo: false, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "Second")
    store.library.tasks.removeAll { $0.id == "b" }
    XCTAssertFalse(second.canPerform(redo: false, store: store))
    second.perform(redo: false, store: store)
    XCTAssertEqual(store.library.tasks.count, 1)
    await store.shutdown()
  }

  func testExpiryNoopAndNewRenameInvalidateOnlyTheExpectedHistory() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = TaskRenameHistory(), now = Date()
    try history.rename(store: store, taskID: "b", title: " B ", now: now)
    XCTAssertNil(history.nextExpiration)
    try history.rename(store: store, taskID: "b", title: "B2", now: now)
    XCTAssertTrue(history.canPerform(redo: false, store: store, now: now.addingTimeInterval(59)))
    XCTAssertFalse(history.canPerform(redo: false, store: store, now: now.addingTimeInterval(60)))
    history.expire(now: now.addingTimeInterval(61))
    XCTAssertTrue(history.undoEntries.isEmpty)
    try history.rename(store: store, taskID: "b", title: "B3")
    history.perform(redo: false, store: store)
    XCTAssertTrue(history.canPerform(redo: true, store: store))
    try history.rename(store: store, taskID: "a", title: "A2")
    XCTAssertFalse(history.canPerform(redo: true, store: store))
    await store.shutdown()
  }

  func testFailedRenameDoesNotRegisterHistoryOrInvalidateRedo() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = TaskRenameHistory()
    try history.rename(store: store, taskID: "b", title: "B2")
    history.perform(redo: false, store: store)
    XCTAssertThrowsError(try history.rename(store: store, taskID: "missing", title: "New"))
    XCTAssertTrue(history.canPerform(redo: true, store: store))
    XCTAssertFalse(history.canPerform(redo: false, store: store))
    await store.shutdown()
  }

  func testUndoRestoresExactLegacyTitleAndRedoFailureRetainsRetry() async throws {
    let (store, root) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = "  " + String(repeating: "旧", count: 140) + "  "
    store.library.tasks[1].title = original
    let history = TaskRenameHistory()
    try history.rename(store: store, taskID: "b", title: "New")
    history.perform(redo: false, store: store)
    XCTAssertEqual(store.library.tasks[1].title, original)
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    history.perform(redo: true, store: store)
    XCTAssertTrue(history.failed)
    XCTAssertEqual(store.library.tasks[1].title, original)
    XCTAssertTrue(history.canPerform(redo: true, store: store))
    try FileManager.default.removeItem(at: file)
    history.perform(redo: true, store: store)
    XCTAssertEqual(store.library.tasks[1].title, "New")
    await store.shutdown()
  }
}
