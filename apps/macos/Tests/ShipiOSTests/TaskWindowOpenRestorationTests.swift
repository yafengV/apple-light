import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowOpenRestorationTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-windows-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []),
      .init(id: "b", project: "", title: "B", runIDs: [])]
    store.library.drafts = ["a": "A draft", "b": "B draft"]
    return store
  }

  private func attachedWindow(_ store: WorkspaceStore, id: String, task: String) -> TaskWindowResources {
    let resources = TaskWindowResources()
    resources.prepare(task, store: store, windowID: id)
    let native = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    native.isReleasedWhenClosed = false
    let anchor = NSView()
    native.contentView = anchor
    resources.attach(window: native, from: anchor)
    resources.display(task)
    addTeardownBlock { @MainActor in _ = resources.shutdown(force: true); native.close() }
    return resources
  }

  private func savedRoutes(_ store: WorkspaceStore) throws -> [TaskWindowRoute] {
    let data = try Data(contentsOf: store.dataRoot.appendingPathComponent("workspace.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let routes = try XCTUnwrap(object["openTaskWindowRoutes"] as? [[String: Any]],
      "Saving tab layouts alone cannot reopen the independent task scenes")
    return try JSONDecoder().decode([TaskWindowRoute].self,
      from: JSONSerialization.data(withJSONObject: routes))
  }

  func testNormalShutdownPreservesOpenWindowIdentitiesAndTaskDrafts() async throws {
    let store = try fixture()
    let first = attachedWindow(store, id: "first", task: "a")
    let second = attachedWindow(store, id: "second", task: "b")
    first.tasks["a"]?.newBrowser()
    second.tasks["b"]?.newBrowser(in: .right)
    store.saveLibrary()
    let before = try savedRoutes(store)
    XCTAssertEqual(Set(before.map(\.id)), ["first", "second"])
    XCTAssertTrue(before.allSatisfy { $0.dataRoot == TaskWindowRoute.workspacePath(store.dataRoot) })
    let saved = await store.shutdown()
    XCTAssertTrue(saved)
    XCTAssertEqual(try savedRoutes(store), before)
    let cold = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(cold.drafts, ["a": "A draft", "b": "B draft"])
    XCTAssertEqual(cold.taskWindowTabLayouts["first"]?["a"]?.content.tabs.count, 1)
    XCTAssertEqual(cold.taskWindowTabLayouts["second"]?["b"]?.content.tabs.count, 1)
  }

  func testRestoreWaitsForSuccessfulWorkspaceLoadAndIsConsumedOnlyOnce() throws {
    let store = try fixture()
    let route = TaskWindowRoute(taskID: "a", dataRoot: store.dataRoot, windowID: "first")
    store.library.openTaskWindowRoutes = [route]
    XCTAssertTrue(store.takePendingTaskWindowRoutes().isEmpty)
    XCTAssertFalse(store.taskWindowRestorationClaimed)
    store.scopeLoaded = true
    store.restoringLibrary = true
    XCTAssertTrue(store.takePendingTaskWindowRoutes().isEmpty)
    store.restoringLibrary = false
    store.libraryLoaded = false
    store.libraryReadError = "Controlled read failure"
    XCTAssertTrue(store.takePendingTaskWindowRoutes().isEmpty)
    XCTAssertFalse(store.taskWindowRestorationClaimed)
    store.libraryReadError = nil
    store.libraryLoaded = true
    XCTAssertEqual(store.takePendingTaskWindowRoutes(), [route])
    XCTAssertTrue(store.takePendingTaskWindowRoutes().isEmpty)
    XCTAssertEqual(store.library.drafts, ["a": "A draft", "b": "B draft"])
    XCTAssertNil(store.selection)
  }

  func testAttachedSystemSceneIsNotRequestedAgainAndSameTaskWindowsKeepSeparateIDs() throws {
    let store = try fixture()
    let attached = attachedWindow(store, id: "first", task: "a")
    let second = TaskWindowRoute(taskID: "a", dataRoot: store.dataRoot, windowID: "second")
    store.library.openTaskWindowRoutes.append(second)
    store.scopeLoaded = true
    XCTAssertEqual(store.takePendingTaskWindowRoutes(), [second])
    XCTAssertEqual(attached.displayedTaskID, "a")
    XCTAssertEqual(Set(store.library.openTaskWindowRoutes.map(\.id)), ["first", "second"])
  }

  func testNavigationUpdatesOnlyItsWindowAndManualCloseDoesNotReviveIt() throws {
    let store = try fixture()
    let first = attachedWindow(store, id: "first", task: "a")
    let second = attachedWindow(store, id: "second", task: "a")
    store.selection = "a"
    store.draft = "Keep main input"
    first.prepare("b", store: store)
    first.display("b")
    XCTAssertEqual(store.library.openTaskWindowRoutes.first { $0.id == "first" }?.taskID, "b")
    XCTAssertEqual(store.library.openTaskWindowRoutes.first { $0.id == "second" }?.taskID, "a")
    XCTAssertEqual(store.selection, "a")
    XCTAssertEqual(store.draft, "Keep main input")
    XCTAssertTrue(first.shutdown())
    let cold = WorkspaceStore(dataRoot: store.dataRoot)
    cold.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    cold.libraryLoaded = true
    cold.scopeLoaded = true
    XCTAssertEqual(cold.takePendingTaskWindowRoutes().map(\.id), [second.id])
    XCTAssertNotNil(cold.library.taskWindowTabLayouts["first"]?["b"],
      "Closing a window keeps its layout available for explicit reopening")
  }

  func testBackgroundCacheCannotOpenWindowAndOldResourceCloseCannotRemoveReplacement() throws {
    let store = try fixture()
    let cache = TaskWindowResources()
    cache.prepare("a", store: store, windowID: "cache")
    cache.display("a")
    defer { _ = cache.shutdown(force: true) }
    XCTAssertTrue(store.library.openTaskWindowRoutes.isEmpty)
    let old = attachedWindow(store, id: "shared", task: "a")
    let replacement = attachedWindow(store, id: "shared", task: "b")
    XCTAssertTrue(old.shutdown())
    XCTAssertEqual(store.library.openTaskWindowRoutes.map(\.taskID), ["b"])
    XCTAssertTrue(replacement.shutdown())
    XCTAssertTrue(store.library.openTaskWindowRoutes.isEmpty)
  }

  func testInvalidForeignDeletedAndDuplicateRoutesArePrunedWithoutLosingTasks() throws {
    let store = try fixture()
    let route = TaskWindowRoute(taskID: "a", dataRoot: store.dataRoot, windowID: "first")
    let legacy = try JSONDecoder().decode(TaskWindowRoute.self,
      from: Data(#"{"taskID":"b","windowID":"legacy"}"#.utf8))
    store.library.openTaskWindowRoutes = [route, route, legacy,
      .init(taskID: "a", dataRoot: store.dataRoot.appendingPathComponent("foreign"), windowID: "foreign"),
      .init(taskID: "gone", dataRoot: store.dataRoot, windowID: "missing"),
      .init(taskID: "a", dataRoot: store.dataRoot, windowID: "")]
    store.scopeLoaded = true
    let routes = store.takePendingTaskWindowRoutes()
    XCTAssertEqual(routes.map(\.id), ["first", "legacy"])
    XCTAssertTrue(routes.allSatisfy { $0.dataRoot == TaskWindowRoute.workspacePath(store.dataRoot) })
    XCTAssertEqual(try savedRoutes(store), routes)
    XCTAssertEqual(store.library.tasks.count, 2)
    store.library.tasks[0].archived = true
    store.library.deleteArchivedTasks(["a"])
    XCTAssertEqual(store.library.openTaskWindowRoutes.map(\.taskID), ["b"])
  }

  func testLegacyAndMalformedOptionalRouteCacheRemainLoadable() throws {
    for routes in ["", #", "openTaskWindowRoutes":false"#] {
      let library = try JSONDecoder().decode(WorkspaceLibrary.self,
        from: Data((#"{"drafts":{"a":"keep"}"# + routes + "}").utf8))
      XCTAssertTrue(library.openTaskWindowRoutes.isEmpty)
      XCTAssertEqual(library.drafts["a"], "keep")
    }
  }

  func testOlderLibraryCommitCannotEraseOpenWindowOrResurrectClosedWindow() throws {
    let store = try fixture()
    let beforeOpening = store.library
    let source = attachedWindow(store, id: "first", task: "a")
    try store.commitLibrary(beforeOpening)
    XCTAssertEqual(store.library.openTaskWindowRoutes.map(\.id), ["first"])
    store.rememberTaskWindow(source)
    let beforeClosing = store.library
    XCTAssertTrue(source.shutdown())
    try store.commitLibrary(beforeClosing)
    XCTAssertTrue(store.library.openTaskWindowRoutes.isEmpty)
  }
}
