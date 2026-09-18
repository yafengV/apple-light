import XCTest
@testable import ShipiOS

final class TaskWindowNavigationTests: XCTestCase {
  private let tasks: Set<String> = ["source", "fork", "nested", "other"]

  func testNestedForkHistorySupportsBackForwardAndBranching() {
    var history = TaskWindowNavigation()
    XCTAssertTrue(history.visit("fork", from: "source", available: tasks))
    XCTAssertTrue(history.visit("nested", from: "fork", available: tasks))
    XCTAssertEqual(history.move(backwards: true, current: "nested", available: tasks), "fork")
    XCTAssertEqual(history.move(backwards: true, current: "fork", available: tasks), "source")
    XCTAssertNil(history.move(backwards: true, current: "source", available: tasks))
    XCTAssertEqual(history.move(backwards: false, current: "source", available: tasks), "fork")
    XCTAssertEqual(history.move(backwards: false, current: "fork", available: tasks), "nested")
    XCTAssertEqual(history.move(backwards: true, current: "nested", available: tasks), "fork")
    XCTAssertTrue(history.visit("other", from: "fork", available: tasks))
    XCTAssertNil(history.destination(backwards: false, current: "other", available: tasks))
    XCTAssertEqual(history.move(backwards: true, current: "other", available: tasks), "fork")
  }

  func testDuplicateAndUnavailableVisitsPreserveForwardHistory() {
    var history = TaskWindowNavigation()
    history.visit("fork", from: "source", available: tasks)
    _ = history.move(backwards: true, current: "fork", available: tasks)
    XCTAssertFalse(history.visit("source", from: "source", available: tasks))
    XCTAssertFalse(history.visit("missing", from: "source", available: tasks))
    XCTAssertEqual(history.forward, ["fork"])
    XCTAssertTrue(history.back.isEmpty)
  }

  func testDeletionSkipsMissingEntriesAndDoesNotReintroduceDeletedCurrentTask() {
    var history = TaskWindowNavigation()
    history.visit("fork", from: "source", available: tasks)
    history.visit("nested", from: "fork", available: tasks)
    let surviving: Set<String> = ["source", "other"]
    XCTAssertEqual(history.destination(backwards: true, current: "nested", available: surviving), "source")
    XCTAssertEqual(history.move(backwards: true, current: "nested", available: surviving), "source")
    XCTAssertTrue(history.forward.isEmpty)
    XCTAssertTrue(history.back.isEmpty)
    history.visit("other", from: "source", available: surviving)
    XCTAssertNil(history.move(backwards: true, current: "other", available: ["other"]))
    XCTAssertTrue(history.back.isEmpty)
  }

  @MainActor func testWindowNavigationDoesNotSelectMainTaskOrReplaceDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = tasks.map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.selectTask(store.library.tasks.first { $0.id == "other" }!)
    store.setTaskWindowDraft("Source draft", taskID: "source")
    store.setTaskWindowDraft("Fork draft", taskID: "fork")
    let selection = store.selection, projectSelections = store.library.projectSelections
    let mainHistory = store.navigationBack
    var first = TaskWindowNavigation(), second = TaskWindowNavigation()
    var route = TaskWindowRoute(taskID: "source", dataRoot: root)
    let available = Set(store.library.tasks.map(\.id))
    if first.visit("fork", from: route.taskID, available: available) { route = .init(taskID: "fork", dataRoot: root) }
    if let id = first.move(backwards: true, current: route.taskID, available: available) { route = .init(taskID: id, dataRoot: root) }
    XCTAssertEqual(route.taskID, "source")
    XCTAssertNil(second.move(backwards: true, current: "fork", available: available))
    XCTAssertEqual(store.selection, selection)
    XCTAssertEqual(store.library.projectSelections, projectSelections)
    XCTAssertEqual(store.navigationBack, mainHistory)
    XCTAssertEqual(store.taskWindowDraft("source"), "Source draft")
    XCTAssertEqual(store.taskWindowDraft("fork"), "Fork draft")
    await store.shutdown()
  }
}
