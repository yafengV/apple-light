import XCTest
@testable import ShipiOS

final class CommandMenuSearchTests: XCTestCase {
  private func task(_ id: String, updated: Double = 1) -> WorkspaceTask {
    .init(id: id, project: "", title: id, runIDs: [id], updatedAt: Date(timeIntervalSince1970: updated))
  }

  func testRootSearchThresholdsTrimWhitespaceAndUseClientUTF16Length() {
    XCTAssertFalse(CommandMenuSearch.searchesTasks(" a "))
    XCTAssertTrue(CommandMenuSearch.searchesTasks(" 任务 "))
    XCTAssertFalse(CommandMenuSearch.searchesContent(" 任务 "))
    XCTAssertTrue(CommandMenuSearch.searchesContent("task"))
    XCTAssertTrue(CommandMenuSearch.searchesTasks("🙂"))
    XCTAssertFalse(CommandMenuSearch.searchesContent("🙂"))
  }

  func testMetadataSearchExcludesContentButRetainsBranchMatches() {
    let tasks = [task("message"), task("branch"), task("ab title")]
    var request = TaskSearchRequest(query: "ab", tasks: tasks, names: [:], notes: ["message": "ab message"],
      branches: ["branch": "ab-branch"], runs: [], includeContentResults: false)
    XCTAssertEqual(request.search().map(\.id), ["ab title", "branch"])
    request.includeContentResults = true
    XCTAssertEqual(request.search().map(\.id), ["ab title", "message", "branch"])
  }

  func testRecentsPrioritizeUnreadThenVisitsThenUpdatesAndExcludeHiddenTasks() {
    var library = WorkspaceLibrary()
    library.tasks = [task("current", updated: 100), task("new", updated: 9), task("visited", updated: 1),
      task("unread", updated: 2), task("archived", updated: 300), task("draft", updated: 400)]
    library.tasks[4].archived = true
    library.tasks[5].popoutDraft = true
    library.unreadTasks = ["unread", "archived"]
    library.recentTaskIDs = ["missing", "visited", "visited", "current", "draft"]
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").map(\.id),
      ["unread", "visited", "new"])
    library.tasks += (0..<10).map { task("extra\($0)") }
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").count, 7)
  }

  func testPinnedTasksUseSidebarOrderAndStayOutOfRecents() {
    var library = WorkspaceLibrary()
    library.tasks = [task("a"), task("b"), task("current"), task("archived"), task("recent")]
    for index in 0...3 { library.tasks[index].pinned = true }
    library.tasks[3].archived = true
    library.sidebar.order[SidebarLayout.pinned] = ["t:b", "t:a", "t:current"]
    XCTAssertEqual(CommandMenuSearch.pinned(library: library, currentID: "current").map(\.id),
      ["b", "a"])
    XCTAssertEqual(CommandMenuSearch.recent(library: library, currentID: "current").map(\.id),
      ["recent"])
  }

  func testCommandGroupsFollowCurrentCodexMenuCategories() {
    let groups = Dictionary(uniqueKeysWithValues: DesktopCommand.all.map { ($0.id, $0.group) })
    XCTAssertEqual(groups["archive"], .chat)
    XCTAssertEqual(groups["open-task-window"], .chat)
    XCTAssertEqual(groups["next-task"], .navigation)
    XCTAssertEqual(groups["focus-chat-1"], .navigation)
    XCTAssertEqual(groups["browser-new"], .panels)
    XCTAssertEqual(groups["focus-tab-1"], .panels)
    XCTAssertEqual(groups["branch"], .project)
    XCTAssertEqual(groups["settings"], .configure)
    XCTAssertEqual(groups["open-skills"], .skills)
    XCTAssertEqual(groups["reload-skills"], .skills)
    XCTAssertEqual(groups["pet"], .app)
  }

  @MainActor func testOpenTaskWindowCommandUsesSelectedTaskAndWorkspaceRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let task = task("current")
    store.library.tasks = [task]
    store.selectTask(task)
    XCTAssertTrue(store.commandEnabled("open-task-window"))
    store.executeCommand("open-task-window")
    let first = try XCTUnwrap(store.taskWindowOpenRequest)
    XCTAssertEqual(first.taskID, task.id)
    XCTAssertEqual(first.dataRoot, TaskWindowRoute.workspacePath(root))
    store.executeCommand("open-task-window")
    let second = try XCTUnwrap(store.taskWindowOpenRequest)
    XCTAssertNotEqual(first.id, second.id, "Each command opens another window for the same task")
    store.taskWindowOpenRequest = nil
    store.openSettings()
    XCTAssertFalse(store.commandEnabled("open-task-window"))
    store.executeCommand("open-task-window")
    XCTAssertNil(store.taskWindowOpenRequest)
    await store.shutdown()
  }

  func testVisitOrderMigratesPersistsAndPrunesDeletedTasks() throws {
    var library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(library.recentTaskIDs.isEmpty)
    library.tasks = [task("a"), task("b"), task("draft")]
    library.tasks[2].popoutDraft = true
    XCTAssertTrue(library.recordTaskVisit("a"))
    XCTAssertTrue(library.recordTaskVisit("b"))
    XCTAssertTrue(library.recordTaskVisit("a"))
    XCTAssertFalse(library.recordTaskVisit("a"))
    XCTAssertFalse(library.recordTaskVisit("draft"))
    XCTAssertFalse(library.recordTaskVisit("missing"))
    let restored = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    XCTAssertEqual(restored.recentTaskIDs, ["a", "b"])
    library.tasks[0].archived = true
    library.deleteArchivedTasks(["a"])
    XCTAssertEqual(library.recentTaskIDs, ["b"])
  }

  @MainActor func testFirstNavigationRecordsRestoredTaskAndPersistsNewVisitWithoutChangingDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [task("a"), task("b")]
    store.library.drafts = ["a": "Draft A", "b": "Draft B"]
    store.selection = "a"
    store.selectTask(store.library.tasks[1])
    XCTAssertEqual(store.library.recentTaskIDs, ["b", "a"])
    XCTAssertEqual(store.library.drafts, ["a": "Draft A", "b": "Draft B"])
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.recentTaskIDs, ["b", "a"])
    await store.shutdown()
  }

}
