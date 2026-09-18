import XCTest
@testable import ShipiOS

final class TaskWindowRestorationTests: XCTestCase {
  func testSavedRouteRetainsWorkspaceIdentityAndLegacyRoutesRemainDecodable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let route = TaskWindowRoute(taskID: "shared-id", dataRoot: root)
    let restored = try JSONDecoder().decode(TaskWindowRoute.self, from: JSONEncoder().encode(route))
    XCTAssertEqual(restored, route)
    XCTAssertNotEqual(route, TaskWindowRoute(taskID: route.taskID, dataRoot: root.appendingPathComponent("other")))
    let legacy = try JSONDecoder().decode(TaskWindowRoute.self, from: Data(#"{"taskID":"old-task"}"#.utf8))
    XCTAssertNil(legacy.dataRoot)
    XCTAssertEqual(legacy.taskID, "old-task")
  }

  func testSymlinkedWorkspaceUsesTheSameWindowIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let actual = root.appendingPathComponent("actual"), link = root.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
    XCTAssertEqual(TaskWindowRoute(taskID: "task", dataRoot: actual), TaskWindowRoute(taskID: "task", dataRoot: link))
  }

  func testForeignWorkspaceClosesEvenWhenTaskIDsCollideOrCurrentWorkspaceHasNotLoaded() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let route = TaskWindowRoute(taskID: "same-id", dataRoot: root.appendingPathComponent("first"))
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root.appendingPathComponent("second"),
      loaded: false, restoring: true, readError: nil, taskExists: true, hasPresentedTask: false), .close)
  }

  func testMissingTaskWaitsForLoadAndOnlyClosesWhenInitiallyRestored() {
    let root = FileManager.default.temporaryDirectory
    let route = TaskWindowRoute(taskID: "task", dataRoot: root)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: nil, dataRoot: root, loaded: true,
      restoring: false, readError: nil, taskExists: false, hasPresentedTask: false), .loading)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root, loaded: false,
      restoring: false, readError: nil, taskExists: false, hasPresentedTask: false), .loading)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root, loaded: true,
      restoring: true, readError: nil, taskExists: true, hasPresentedTask: false), .loading)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root, loaded: true,
      restoring: false, readError: nil, taskExists: false, hasPresentedTask: false), .close)
    XCTAssertEqual(TaskWindowRestoration.resolve(route: route, dataRoot: root, loaded: true,
      restoring: false, readError: nil, taskExists: false, hasPresentedTask: true), .ready("task"))
  }

  @MainActor func testCorruptWorkspacePreservesRestoredRouteUntilSuccessfulRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("workspace.json")
    try Data("invalid".utf8).write(to: file)
    let legacy = try JSONDecoder().decode(TaskWindowRoute.self, from: Data(#"{"taskID":"saved"}"#.utf8))
    let store = WorkspaceStore(dataRoot: root)
    func resolution() -> TaskWindowRestoration {
      .resolve(route: legacy, dataRoot: store.dataRoot, loaded: store.libraryLoaded,
        restoring: store.restoringLibrary || store.libraryLoading, readError: store.libraryReadError,
        taskExists: store.library.tasks.contains { $0.id == legacy.taskID }, hasPresentedTask: false)
    }
    await store.restore()
    guard case .failed = resolution() else { return XCTFail("A read error must not dismiss the restored window") }
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "saved", project: "", title: "Saved", runIDs: [])]
    library.drafts["saved"] = "Pending draft"
    try library.save(to: file)
    await store.restore()
    XCTAssertEqual(resolution(), .ready("saved"))
    XCTAssertEqual(store.taskWindowDraft("saved"), "Pending draft")
    await store.shutdown()
  }
}
