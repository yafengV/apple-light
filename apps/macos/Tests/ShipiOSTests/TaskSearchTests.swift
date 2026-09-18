import SQLite3
import XCTest
@testable import ShipiOS

final class TaskSearchTests: XCTestCase {
  private func run(_ id: String, project: String = "/project", kind: String = "chat", response: String = "", updated: Double = 1) -> AgentRun {
    AgentRun(id: id, kind: kind, project: project, status: "running", createdAt: 1, updatedAt: updated,
      request: .object(["kind": .string(kind)]), result: .object(["response": .string(response)]))
  }
  private func request(_ query: String, library: WorkspaceLibrary, runs: [AgentRun] = []) -> TaskSearchRequest {
    TaskSearchRequest(query: query, tasks: library.tasks, names: library.projectNames,
      notes: library.notes, branches: library.runBranches, runs: library.localRuns + runs)
  }
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-search-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func database(_ file: URL, runs: [AgentRun], version: Int = 1) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE runs (id TEXT PRIMARY KEY, body TEXT NOT NULL); PRAGMA user_version=\(version);", nil, nil, nil), SQLITE_OK)
    for run in runs {
      let body = String(decoding: try JSONEncoder().encode(run), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
      let id = run.id.replacingOccurrences(of: "'", with: "''")
      XCTAssertEqual(sqlite3_exec(db, "INSERT INTO runs VALUES ('\(id)', '\(body)');", nil, nil, nil), SQLITE_OK)
    }
  }

  func testSearchIncludesArchivedAndProjectlessDisplayedMarkdownAndCode() {
    var library = WorkspaceLibrary()
    library.tasks = [
      .init(id: "first", project: "/project", title: "Renamed", runIDs: ["one"], archived: true),
      .init(id: "second", project: "", title: "Standalone", runIDs: ["two"]),
    ]
    library.chatRuns = [run("one", response: "Use **Café** here.\n\n```swift\nlet emoji = \"👩🏽‍💻目标\"\n```"),
      run("two", project: "", response: "| Field | Value |\n| --- | --- |\n| result | table-needle |")]
    XCTAssertTrue(request("cafe", library: library).search().isEmpty)
    XCTAssertEqual(request("café", library: library).search().first?.id, "first")
    XCTAssertEqual(request("Use Café here", library: library).search().first?.source, "回答")
    XCTAssertEqual(request("👩🏽‍💻目标", library: library).search().first?.id, "first")
    XCTAssertEqual(request("table-needle", library: library).search().first?.id, "second")
    XCTAssertEqual(request("**Café**", library: library).search().first?.id, "first")
    XCTAssertTrue(request("```swift", library: library).search().isEmpty)
    XCTAssertEqual(request(" \n ", library: library).search().map(\.id), ["first", "second"])
  }

  func testHistoricalBranchesPromptProjectAndLatestResult() {
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "Title", runIDs: ["one", "two"])]
    library.projectNames["/project"] = "My Project"
    library.runBranches = ["one": "fix/login-redirect", "two": "release"]
    library.notes["one"] = "A very early prompt"
    library.chatRuns = [run("one", response: "obsolete", updated: 1)]
    XCTAssertEqual(request("early", library: library).search().first?.source, "消息")
    XCTAssertEqual(request("LOGIN-REDIRECT", library: library).search().first?.snippet, "fix/login-redirect")
    XCTAssertEqual(request("my project", library: library).search().first?.id, "task")
    let latest = run("one", response: "current answer", updated: 2)
    XCTAssertTrue(request("obsolete", library: library, runs: [latest]).search().isEmpty)
    XCTAssertEqual(request("current answer", library: library, runs: [latest]).search().first?.id, "task")
  }

  func testExcerptPreservesUnicodeAndKeyboardSkipsUnavailableRows() {
    let text = String(repeating: "🙂", count: 200) + "Cafe\u{301} 目标" + String(repeating: "文", count: 200)
    let excerpt = TaskSearchRequest.excerpt(text, query: "cafe")
    XCTAssertTrue(excerpt.hasPrefix("…")); XCTAssertTrue(excerpt.hasSuffix("…"))
    XCTAssertTrue(excerpt.contains("Cafe\u{301} 目标")); XCTAssertLessThan(excerpt.count, 180)
    XCTAssertEqual(TaskSearchRequest.nextSelection("unavailable", ids: ["a", "c"], offset: 1), "a")
    XCTAssertEqual(TaskSearchRequest.nextSelection("a", ids: ["a", "c"], offset: 1), "c")
    XCTAssertEqual(TaskSearchRequest.nextSelection("c", ids: ["a", "c"], offset: 1), "c")
    XCTAssertNil(TaskSearchRequest.nextSelection("a", ids: [], offset: -1))
  }

  func testReadonlyHistoryDoesNotInterruptActiveRunsAndFiltersForeignRecords() throws {
    let root = try temporaryRoot()
    let active = run("known", kind: "doctor")
    let file = TaskSearchHistory.database(root: root, project: "/project")
    try database(file, runs: [active, run("unowned"), run("foreign", project: "/other")])
    let before = try Data(contentsOf: file)
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "Title", runIDs: ["known", "foreign"])]
    let found = TaskSearchHistory.load(root: root, library: library)
    XCTAssertTrue(found.errors.isEmpty)
    XCTAssertEqual(found.runs, [active])
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(try TaskSearchHistory.read(file).first(where: { $0.id == "known" })?.status, "running")
  }

  func testHistoryPartialFailuresAndDatabaseVersionAreReportedWithoutCreatingFiles() throws {
    let root = try temporaryRoot()
    var library = WorkspaceLibrary()
    library.tasks = [
      .init(id: "good", project: "/good", title: "Good", runIDs: ["good"]),
      .init(id: "missing", project: "/missing", title: "Missing", runIDs: ["missing"]),
      .init(id: "newer", project: "/newer", title: "Newer", runIDs: ["newer"]),
    ]
    try database(TaskSearchHistory.database(root: root, project: "/good"), runs: [run("good", project: "/good")])
    try database(TaskSearchHistory.database(root: root, project: "/newer"), runs: [], version: 2)
    let found = TaskSearchHistory.load(root: root, library: library)
    XCTAssertEqual(found.runs.map(\.id), ["good"])
    XCTAssertEqual(found.errors.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: TaskSearchHistory.database(root: root, project: "/missing").path))
  }

  func testSearchLocalExecutionDiagnosticsAndDoesNotLeakOtherProjectContent() {
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "Build", runIDs: ["one"])]
    let result: JSONValue = .object(["command": .object([
      "stdout": .string("compiler output needle"), "stderr": .string("stderr needle"),
      "diagnostics": .array([.object(["message": .string("missing-symbol-needle")])])])])
    let build = AgentRun(id: "one", kind: "build", project: "/project", status: "failed", createdAt: 1, updatedAt: 1, request: .null, result: result)
    XCTAssertEqual(request("compiler output", library: library, runs: [build]).search().first?.source, "执行结果")
    XCTAssertEqual(request("missing-symbol", library: library, runs: [build]).search().first?.source, "诊断")
    XCTAssertTrue(request("foreign secret", library: library, runs: [run("one", project: "/other", response: "foreign secret")]).search().isEmpty)
  }

  @MainActor func testMissingTmpAliasHistoryCanRetryAndPopulateCurrentQuery() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/task-search-retry-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "History", runIDs: ["one"])]
    let file = TaskSearchHistory.database(root: root, project: "/project")
    let catalog = TaskSearchCatalog()
    await catalog.load(root: root, library: library)
    XCTAssertEqual(catalog.historyErrors, ["project：无法读取本地任务历史"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    await catalog.search(request("retry-needle", library: library, runs: catalog.history))
    XCTAssertTrue(catalog.results.isEmpty)

    try database(file, runs: [run("one", response: "Recovered retry-needle")])
    await catalog.load(root: root, library: library)
    await catalog.search(request("retry-needle", library: library, runs: catalog.history))
    XCTAssertTrue(catalog.historyErrors.isEmpty)
    XCTAssertFalse(catalog.loading)
    XCTAssertEqual(catalog.results.map(\.id), ["task"])
    XCTAssertEqual(catalog.results.first?.snippet, "Recovered retry-needle")
  }

  func testHistoryRejectsExternalSymlinks() throws {
    let root = try temporaryRoot()
    let outside = try temporaryRoot().appendingPathComponent("outside.sqlite")
    try database(outside, runs: [run("one", response: "outside")])
    let file = TaskSearchHistory.database(root: root, project: "/project")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "Task", runIDs: ["one"])]
    let loaded = TaskSearchHistory.load(root: root, library: library)
    XCTAssertTrue(loaded.runs.isEmpty)
    XCTAssertEqual(loaded.errors.count, 1)
  }

  @MainActor func testCancelledSearchCannotReplaceTheLastCompletedResults() async {
    var library = WorkspaceLibrary()
    library.tasks = [.init(id: "task", project: "/project", title: "Retained", runIDs: [])]
    let catalog = TaskSearchCatalog()
    await catalog.search(request("Retained", library: library))
    let pending = Task { await catalog.search(request("no match", library: library)) }
    pending.cancel()
    await pending.value
    XCTAssertEqual(catalog.results.map(\.id), ["task"])
    XCTAssertEqual(catalog.resultsQuery, "Retained")
    await catalog.search(request("no match", library: library))
    XCTAssertTrue(catalog.results.isEmpty)
    XCTAssertFalse(catalog.searching)
  }

  func testBranchesSurvivePersistenceAndForkBoundaryAndLegacyData() throws {
    let root = try temporaryRoot()
    var library = WorkspaceLibrary()
    let first = AgentRun(id: "one", kind: "chat", project: "/project", status: "succeeded", createdAt: 1, updatedAt: 1, request: .null, result: nil)
    let second = AgentRun(id: "two", kind: "chat", project: "/project", status: "succeeded", createdAt: 2, updatedAt: 2, request: .null, result: nil)
    library.tasks = [.init(id: "task", project: "/project", title: "Original", runIDs: ["one", "two"])]
    library.runBranches = ["one": "original", "two": "later"]
    let fork = try library.forkConversation(taskID: "task", through: "one", availableRuns: [first, second])
    try library.save(to: root.appendingPathComponent("workspace.json"))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.runBranches[fork.runIDs[0]], "original")
    XCTAssertEqual(request("later", library: restored).search().map(\.id), ["task"])
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).runBranches.isEmpty)
  }

  @MainActor func testBranchCaptureReadsActualRepositoryAndIgnoresNonGitProject() async throws {
    let root = try temporaryRoot()
    _ = try await LocalWorkspaceService.git(["init", "-q", "-b", "first"], at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    store.project = root
    let first = await store.branchForTaskHistory()
    XCTAssertEqual(first, "first")
    _ = try await LocalWorkspaceService.git(["symbolic-ref", "HEAD", "refs/heads/changed-outside-app"], at: root)
    let changed = await store.branchForTaskHistory()
    XCTAssertEqual(changed, "changed-outside-app")
    let child = root.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    store.project = child
    let noParentBranch = await store.branchForTaskHistory()
    XCTAssertNil(noParentBranch)
    store.project = nil
    let projectless = await store.branchForTaskHistory()
    XCTAssertNil(projectless)
    await store.shutdown()
  }
}
