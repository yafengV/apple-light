import XCTest
@testable import ShipiOS

final class ArchivedTaskPresentationTests: XCTestCase {
  private func task(_ id: String, _ project: String, _ title: String, created: Double = 1,
    updated: Double = 2) -> WorkspaceTask {
    .init(id: id, project: project, title: title, runIDs: [], archived: true,
      archivedAt: Date(timeIntervalSince1970: 999), createdAt: Date(timeIntervalSince1970: created),
      updatedAt: Date(timeIntervalSince1970: updated))
  }
  private func run(_ id: String, created: Double, updated: Double, automation: Bool = false) -> AgentRun {
    .init(id: id, kind: "chat", project: "/a", status: "completed", createdAt: created * 1000,
      updatedAt: updated * 1000, request: automation ? .object(["automation_id": .string("auto")]) : .object([:]), result: nil)
  }
  func testDefaultGroupsUseLatestContentTimeAndProjectNamesNotArchiveTime() {
    var library = WorkspaceLibrary()
    library.projectNames = ["/a": "Alpha", "/b": "Beta"]
    library.tasks = [task("a", "/a", "Zoo", updated: 10), task("b", "/b", "Bee", updated: 30),
      task("c", "/a", "Apple", updated: 20), task("none", "", "No project", updated: 5)]
    library.tasks[0].archivedAt = Date(timeIntervalSince1970: 999999)
    var active = task("active", "/b", "Active", updated: 100); active.archived = false
    var draft = task("draft", "/b", "Draft", updated: 100); draft.popoutDraft = true
    library.tasks += [active, draft]
    let groups = ArchivedTaskPresentation(library: library).groups(query: "", project: .all, kind: .all, sort: .updated)
    XCTAssertEqual(groups.map(\.title), ["Beta", "Alpha", "无项目"])
    XCTAssertEqual(groups[1].entries.map(\.id), ["c", "a"])
    XCTAssertEqual(groups.flatMap(\.entries).count, 4)
  }
  func testProjectIdentitySearchAndSort() {
    var library = WorkspaceLibrary()
    library.projectNames = ["/a": "Same", "/b": "Same"]
    library.tasks = [task("a", "/a", "Zulu", created: 30, updated: 2),
      task("b", "/a", "Alpha", created: 10, updated: 8), task("c", "/b", "Alpha", created: 40)]
    let value = ArchivedTaskPresentation(library: library)
    XCTAssertEqual(value.projects.map(\.path), ["/a", "/b"])
    func ids(_ sort: ArchivedTaskSort, _ query: String = "") -> [String] {
      value.groups(query: query, project: .project("/a"), kind: .local, sort: sort).flatMap(\.entries).map(\.id)
    }
    XCTAssertEqual(ids(.created), ["a", "b"])
    XCTAssertEqual(ids(.updated), ["b", "a"])
    XCTAssertEqual(ids(.alphabetical), ["b", "a"])
    XCTAssertEqual(ids(.updated, " alhpa "), ["b"])
    XCTAssertEqual(ids(.updated, " alpha SAME "), [], "Search fields must not be concatenated")
    XCTAssertEqual(value.groups(query: "missing", project: .all, kind: .all, sort: .updated).count, 0)
    XCTAssertEqual(value.effectiveFilter(.project("/removed")), .all)
  }
  func testProjectlessScheduledAndCloudFiltersDoNotMisclassifyAPIChats() {
    var library = WorkspaceLibrary()
    library.tasks = [task("plain", "", "Plain"), task("auto", "", "Schedule"),
      task("in-project", "/a", "Project automation"), task("project", "/a", "API chat")]
    library.tasks[2].runIDs = ["run"]
    library.chatRuns = [run("run", created: 1, updated: 3, automation: true)]
    let value = ArchivedTaskPresentation(library: library, automationTaskIDs: ["auto"])
    func ids(_ project: ArchivedProjectFilter, _ kind: ArchivedTaskKind = .all) -> Set<String> {
      Set(value.groups(query: "", project: project, kind: kind, sort: .updated).flatMap(\.entries).map(\.id))
    }
    XCTAssertEqual(ids(.projectless), ["plain"])
    XCTAssertEqual(ids(.automations), ["auto", "in-project"])
    XCTAssertEqual(ids(.project("/a")), ["project"])
    XCTAssertEqual(ids(.all, .local).count, 4)
    XCTAssertTrue(ids(.all, .cloud).isEmpty)
  }
  func testLegacyDatesAreRecoveredFromRunsAndPersistAcrossProjectSwitches() throws {
    let old = Data(#"{"id":"legacy","project":"/a","title":"Legacy","runIDs":["early","late"],"pinned":false,"archived":true}"#.utf8)
    let legacy = try JSONDecoder().decode(WorkspaceTask.self, from: old)
    XCTAssertNil(legacy.createdAt)
    var library = WorkspaceLibrary(); library.tasks = [legacy]
    library.reconcile([run("late", created: 20, updated: 40), run("early", created: 5, updated: 10)], project: "/a")
    let reloaded = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(library))
    let entry = try XCTUnwrap(ArchivedTaskPresentation(library: reloaded).entries.first)
    XCTAssertEqual(entry.createdAt?.timeIntervalSince1970, 5)
    XCTAssertEqual(entry.updatedAt?.timeIntervalSince1970, 40)
    XCTAssertTrue(entry.task.archived)
    let newer = ArchivedTaskPresentation(library: reloaded, runs: [run("late", created: 20, updated: 60)])
    XCTAssertEqual(newer.entries.first?.updatedAt?.timeIntervalSince1970, 60)
  }
  func testMissingDatesStayUnknownAndEqualKeysHaveStableOrdering() {
    var library = WorkspaceLibrary()
    library.tasks = [task("b", "/a", "Same"), task("a", "/a", "Same")]
    library.tasks += [.init(id: "unknown", project: "/a", title: "Unknown", runIDs: [], archived: true)]
    let groups = ArchivedTaskPresentation(library: library).groups(query: "", project: .all, kind: .all, sort: .updated)
    XCTAssertEqual(groups[0].entries.map(\.id), ["a", "b", "unknown"])
    XCTAssertNil(groups[0].entries.last?.updatedAt)
  }
  func testAttachKeepsOriginalCreationAndAdvancesUpdateTime() {
    var library = WorkspaceLibrary()
    library.attach(run("first", created: 10, updated: 20), to: nil, note: "First")
    library.attach(run("second", created: 30, updated: 40), to: "first", note: "Second")
    XCTAssertEqual(library.tasks[0].createdAt?.timeIntervalSince1970, 10)
    XCTAssertEqual(library.tasks[0].updatedAt?.timeIntervalSince1970, 40)
  }
  func testForkCreationDateDoesNotBecomeCopiedHistoryDate() throws {
    var library = WorkspaceLibrary()
    let original = run("original", created: 10, updated: 20)
    library.attach(original, to: nil, note: "Original")
    library.chatRuns = [original]
    let start = Date()
    let fork = try library.forkConversation(taskID: "original", availableRuns: [original])
    library.tasks[0].archived = true
    let entry = try XCTUnwrap(ArchivedTaskPresentation(library: library).entries.first { $0.id == fork.id })
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(entry.createdAt), start)
    XCTAssertEqual(entry.createdAt, fork.createdAt)
  }
  @MainActor func testConfirmedDeletionIDsExcludeNewRestoredAndOtherProjectTasks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [task("delete", "/a", "Delete"), task("restore", "/a", "Restore"), task("other", "/b", "Other")]
    let confirmedIDs: Set<String> = ["delete", "restore"]
    XCTAssertTrue(store.restoreArchivedTask("restore"))
    store.library.tasks.append(task("new", "/a", "Newly archived"))
    store.deleteArchivedTasks(confirmedIDs)
    XCTAssertEqual(Set(store.library.tasks.map(\.id)), ["restore", "other", "new"])
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertFalse(try XCTUnwrap(saved.tasks.first { $0.id == "restore" }).archived)
  }
  @MainActor func testRestoreSaveFailureRetainsArchiveAndShowsError() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [task("a", "/a", "A")]
    XCTAssertFalse(store.restoreArchivedTask("a"))
    XCTAssertTrue(store.library.tasks[0].archived)
    XCTAssertNotNil(store.library.tasks[0].archivedAt)
    XCTAssertNotNil(store.archivedTaskDeletionError)
  }
}
