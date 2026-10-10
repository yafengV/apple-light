import XCTest

@testable import ShipiOS

final class WorkspaceRestorationTests: XCTestCase {
  @MainActor func testMissingLastProjectReportsFailureWithoutReplacingSavedRecoveryLocation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let missing = root.resolvingSymlinksInPath().appendingPathComponent("missing project")
    var saved = WorkspaceLibrary()
    saved.projects = [missing.path]
    saved.lastWorkspace = missing.path
    saved.tasks = [.init(id: "saved-task", project: missing.path, title: "Saved", runIDs: [])]
    saved.projectSelections[missing.path] = "saved-task"
    saved.drafts["saved-task"] = "Keep this draft"
    saved.unreadTasks = ["saved-task"]
    let file = root.appendingPathComponent("data/workspace.json")
    try saved.save(to: file)
    let helper = try XCTUnwrap(ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"])
    let store = WorkspaceStore(dataRoot: file.deletingLastPathComponent(), agentExecutable: URL(fileURLWithPath: helper))
    await store.restore()
    XCTAssertTrue(store.libraryLoaded)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.busy)
    XCTAssertTrue(store.error?.contains(missing.path) == true)
    XCTAssertEqual(store.library.lastWorkspace, missing.path)
    XCTAssertEqual(store.library.projectSelections[missing.path], "saved-task")
    XCTAssertEqual(store.library.drafts["saved-task"], "Keep this draft")
    XCTAssertTrue(store.library.unreadTasks.contains("saved-task"))
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).lastWorkspace, missing.path)
    XCTAssertEqual(store.projectRecoveryPath, missing.path)
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    await store.retryProjectOpen()
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.project?.path, missing.path)
    XCTAssertEqual(store.selectedTask?.id, "saved-task")
    XCTAssertEqual(store.draft, "Keep this draft")
    XCTAssertNil(store.projectRecoveryPath)
    XCTAssertNil(store.error)
    await store.shutdown()
  }

  @MainActor func testLibraryReadFailureRemainsDistinctFromEmptyAndClearsAfterSuccessfulRestore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("workspace.json")
    let invalid = Data("invalid workspace".utf8)
    try invalid.write(to: file)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertFalse(store.libraryLoaded)
    XCTAssertFalse(store.libraryLoading)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.busy)
    XCTAssertNotNil(store.libraryReadError)
    XCTAssertEqual(store.error, store.libraryReadError)
    XCTAssertEqual(try Data(contentsOf: file), invalid, "A read failure must not rewrite the workspace")
    store.error = nil
    XCTAssertNotNil(store.libraryReadError, "Dismissing the workspace banner must not make archives look empty")

    var repaired = WorkspaceLibrary()
    repaired.tasks = [.init(id: "archive", project: "", title: "Saved task", runIDs: [], archived: true)]
    try repaired.save(to: file)
    await store.restore()
    XCTAssertTrue(store.libraryLoaded)
    XCTAssertFalse(store.libraryLoading)
    XCTAssertNil(store.libraryReadError)
    XCTAssertEqual(store.library.tasks.map(\.id), ["archive"])
    XCTAssertTrue(store.canMutateArchive)
    store.error = "Unrelated agent failure"
    XCTAssertNil(store.libraryReadError)
    XCTAssertTrue(store.canMutateArchive, "Agent errors are not archive read failures")
  }

  @MainActor func testArchiveActionsCannotRunDuringLibraryLoadOrAfterReadFailure() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "archive", project: "", title: "Saved task", runIDs: [], archived: true)]
    store.openSettings(.archived)
    store.libraryLoading = true
    store.requestArchiveDeletion(.all, ids: ["archive"])
    await store.restoreArchivedTaskWithFeedback("archive")
    XCTAssertNil(store.archiveDeletion)
    XCTAssertTrue(store.library.tasks[0].archived)
    XCTAssertTrue(store.notices.items.isEmpty)
    store.libraryLoading = false
    store.libraryReadError = "Read failed"
    store.requestArchiveDeletion(.all, ids: ["archive"])
    await store.restoreArchivedTaskWithFeedback("archive")
    XCTAssertNil(store.archiveDeletion)
    XCTAssertTrue(store.library.tasks[0].archived)
    XCTAssertTrue(store.notices.items.isEmpty)
    store.libraryReadError = nil
    store.requestArchiveDeletion(.single, ids: ["archive"])
    XCTAssertEqual(store.archiveDeletion?.taskIDs, ["archive"])
  }

  @MainActor func testEmptyDataRootDoesNotOpenGlobalLastProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: "lastProject")
    defaults.set(FileManager.default.temporaryDirectory.path, forKey: "lastProject")
    defer {
      if let previous {
        defaults.set(previous, forKey: "lastProject")
      } else {
        defaults.removeObject(forKey: "lastProject")
      }
    }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    XCTAssertNil(store.project)
    XCTAssertFalse(store.restoringLibrary)
    XCTAssertFalse(store.busy)
    XCTAssertNil(store.error)
    XCTAssertTrue(store.library.projects.isEmpty)
  }

  @MainActor func testRestorationAndAppearanceWritesStayInTheirOwnDataRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstRoot = root.appendingPathComponent("first")
    let secondRoot = root.appendingPathComponent("second")
    var first = WorkspaceLibrary()
    first.appearance = AppearancePreferences()
    first.appearance?.codeSize = 18
    first.drafts["new:none"] = "first draft"
    try first.save(to: firstRoot.appendingPathComponent("workspace.json"))
    var second = WorkspaceLibrary()
    second.drafts["new:none"] = "second draft"
    try second.save(to: secondRoot.appendingPathComponent("workspace.json"))
    let a = WorkspaceStore(dataRoot: firstRoot)
    let b = WorkspaceStore(dataRoot: secondRoot)
    await a.restore()
    await b.restore()
    XCTAssertEqual(a.appearance.codeSize, 18)
    XCTAssertEqual(b.appearance.codeSize, 12)
    XCTAssertEqual(a.draft, "first draft")
    XCTAssertEqual(b.draft, "second draft")
    a.appearance = AppearancePreferences()
    let saved = try WorkspaceLibrary.load(from: secondRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.drafts["new:none"], "second draft")
    XCTAssertEqual(b.draft, "second draft")
    XCTAssertNil(a.project)
    XCTAssertNil(b.project)
  }
}
