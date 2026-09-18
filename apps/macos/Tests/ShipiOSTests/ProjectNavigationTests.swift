import XCTest

@testable import ShipiOS

final class ProjectNavigationTests: XCTestCase {
  @MainActor func testRenameReentrySeedsEachTargetBeforePresenting() {
    let store = WorkspaceStore()
    store.library.projects = ["/a", "/b"]
    store.library.projectNames = ["/a": "Application", "/b": "Backend"]
    store.library.tasks = [task("task", project: "/a")]
    store.beginRenamingProject("/a")
    XCTAssertEqual(store.renameDraft, "Application")
    store.renameDraft = "cancelled edit"
    store.renameProjectPath = nil
    store.beginRenamingProject("/b")
    XCTAssertEqual(store.renameDraft, "Backend")
    store.beginRenamingTask("task")
    XCTAssertEqual(store.renameDraft, "task")
    XCTAssertNil(store.renameProjectPath)
  }

  private func task(_ id: String, project: String, pinned: Bool = false, archived: Bool = false)
    -> WorkspaceTask
  {
    WorkspaceTask(
      id: id, project: project, title: id, runIDs: [id], pinned: pinned, archived: archived)
  }

  func testLegacyProjectDataAndPersistentOrganization() throws {
    var library = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: Data(#"{"projects":["/a","/b"]}"#.utf8))
    XCTAssertTrue(library.collapsedProjects.isEmpty)
    XCTAssertTrue(library.projectSelections.isEmpty)
    library.collapsedProjects.insert("/a")
    library.pinnedProjects.insert("/b")
    library.projectSelections["/a"] = ""
    library.projectNames["/a"] = "Application"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try library.save(to: file)
    let loaded = try WorkspaceLibrary.load(from: file)
    XCTAssertEqual(loaded.collapsedProjects, ["/a"])
    XCTAssertEqual(loaded.orderedProjects, ["/b", "/a"])
    XCTAssertEqual(loaded.projectSelections["/a"], "")
    XCTAssertEqual(loaded.projectTitle("/a"), "Application")
  }

  func testRememberedSelectionDistinguishesNewTaskMissingTaskAndArchivedTask() {
    var library = WorkspaceLibrary()
    library.tasks = [
      task("latest", project: "/a"), task("previous", project: "/a"), task("other", project: "/b"),
    ]
    XCTAssertEqual(library.rememberedSelection(project: "/a"), "latest")
    library.projectSelections["/a"] = "previous"
    XCTAssertEqual(library.rememberedSelection(project: "/a"), "previous")
    library.tasks[1].archived = true
    XCTAssertEqual(library.rememberedSelection(project: "/a"), "latest")
    library.projectSelections["/a"] = "other"
    XCTAssertEqual(library.rememberedSelection(project: "/a"), "latest")
    library.projectSelections["/a"] = ""
    XCTAssertNil(library.rememberedSelection(project: "/a"))
  }

  @MainActor func testTaskSelectionRevealsProjectClearsUnreadAndPreservesDrafts() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/a")
    store.connected = true
    let first = task("first", project: "/a")
    let second = task("second", project: "/a")
    store.library.tasks = [first, second]
    store.library.collapsedProjects = ["/a", "/b"]
    store.library.unreadTasks = ["second"]
    store.selection = "first"
    store.draft = "first draft"
    store.selectTask(second)
    store.draft = "second draft"
    XCTAssertFalse(store.library.collapsedProjects.contains("/a"))
    XCTAssertTrue(store.library.collapsedProjects.contains("/b"))
    XCTAssertFalse(store.library.unreadTasks.contains("second"))
    XCTAssertEqual(store.library.projectSelections["/a"], "second")
    store.selectTask(first)
    XCTAssertEqual(store.draft, "first draft")
    XCTAssertEqual(store.library.drafts["second"], "second draft")
  }

  @MainActor func testActiveRunPreventsSwitchingAgentToAnotherProject() {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/a")
    store.connected = true
    store.runs = [
      AgentRun(
        id: "running", kind: "doctor", project: "/a", status: "running",
        createdAt: 0, updatedAt: 0, request: .null, result: nil)
    ]
    store.selection = "running"
    let other = task("other", project: "/b")
    XCTAssertFalse(store.canSelectTask(other))
    store.selectTask(other)
    XCTAssertEqual(store.selection, "running")
    XCTAssertEqual(store.project?.path, "/a")
    XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertTrue(store.canSelectTask(task("same", project: "/a")))
  }

  @MainActor func testProjectMenusKeepIdentityAndArchiveOnlyIdleTasks() {
    let store = WorkspaceStore()
    store.library.projects = ["/a", "/b"]
    store.library.tasks = [
      task("idle", project: "/a"), task("running", project: "/a"), task("other", project: "/b"),
    ]
    store.runs = [
      AgentRun(
        id: "running", kind: "doctor", project: "/a", status: "running",
        createdAt: 0, updatedAt: 0, request: .null, result: nil)
    ]
    store.renameProject("/a", title: " Application ")
    store.toggleProjectPin("/b")
    store.archiveProject("/a")
    XCTAssertEqual(store.library.projectTitle("/a"), "Application")
    XCTAssertEqual(store.library.tasks[0].project, "/a")
    XCTAssertEqual(store.library.orderedProjects, ["/b", "/a"])
    XCTAssertTrue(store.library.tasks[0].archived)
    XCTAssertNotNil(store.library.tasks[0].archivedAt)
    XCTAssertFalse(store.library.tasks[1].archived)
    XCTAssertFalse(store.library.tasks[2].archived)
  }

  @MainActor func testNewTaskInCurrentProjectRemembersItsDraftSlot() async {
    let store = WorkspaceStore()
    store.connected = true
    store.project = URL(fileURLWithPath: "/a")
    store.library.tasks = [task("previous", project: "/a")]
    store.selection = "previous"
    store.draft = "previous draft"
    store.library.collapsedProjects.insert("/a")
    await store.newTask(in: "/a")
    store.draft = "new draft"
    XCTAssertNil(store.selection)
    XCTAssertEqual(store.library.projectSelections["/a"], "")
    XCTAssertFalse(store.library.collapsedProjects.contains("/a"))
    XCTAssertEqual(store.library.drafts["previous"], "previous draft")
    XCTAssertEqual(store.library.drafts["new:/a"], "new draft")
  }
}
