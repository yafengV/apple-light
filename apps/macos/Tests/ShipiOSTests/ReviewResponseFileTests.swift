import XCTest

@testable import ShipiOS

@MainActor final class ReviewResponseFileTests: XCTestCase {
  func testNestedReviewLinksUseSavedRepositoryRatherThanProjectDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("App", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("repository file".utf8).write(to: root.appendingPathComponent("shared.swift"))
    try Data("different child file".utf8).write(to: child.appendingPathComponent("shared.swift"))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    let run = AgentRun(id: UUID().uuidString, kind: "chat", project: child.path,
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["conversation_kind": .string("review"),
        "review_repository_root": .string(root.path)]),
      result: .object(["response": .string("[shared](shared.swift#L3)")]))
    let base = try XCTUnwrap(store.responseFileRoot(for: run))
    let files = TaskSummaryLinkedFiles.collect([run], rootForRun: { store.responseFileRoot(for: $0) })
    XCTAssertEqual(base.path, root.path)
    XCTAssertEqual(files.first?.url.path, root.appendingPathComponent("shared.swift").path)
    XCTAssertEqual(store.workspaceRoot(for: run)?.path, child.path)
  }

  func testLegacyReviewReadsOriginalSnapshotAcrossRestartAndNewGitBoundary() throws {
    let (root, child, store) = try fixture()
    let run = reviewRun(project: child, root: nil)
    let snapshot = ModelCodeReviewSnapshot(scope: .uncommitted, diff: "original diff",
      repositoryRoot: root.path)
    try ReviewSnapshotStorage.save(snapshot, runID: run.id, root: store.dataRoot)
    try FileManager.default.createDirectory(at: child.appendingPathComponent(".git"),
      withIntermediateDirectories: true)
    XCTAssertEqual(store.responseFileRoot(for: run)?.path, root.path)
    let decoded = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
    let restarted = WorkspaceStore(dataRoot: store.dataRoot)
    XCTAssertEqual(restarted.responseFileRoot(for: decoded)?.path, root.path)
    XCTAssertEqual(restarted.workspaceRoot(for: decoded)?.path, child.path)
  }

  func testNewReviewRootPersistsWithoutNeedingSnapshotForLinkNavigation() throws {
    let (root, child, store) = try fixture()
    let run = reviewRun(project: child, root: root.path)
    let decoded = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
    XCTAssertEqual(store.responseFileRoot(for: decoded)?.path, root.path)
    XCTAssertThrowsError(try ReviewSnapshotStorage.load(runID: run.id, root: store.dataRoot))
  }

  func testMissingLegacySnapshotDoesNotGuessAndCanRecoverAfterRepair() throws {
    let (root, child, store) = try fixture()
    let run = reviewRun(project: child, root: nil)
    XCTAssertNil(store.responseFileRoot(for: run))
    try ReviewSnapshotStorage.save(.init(scope: .uncommitted, diff: "diff", repositoryRoot: root.path),
      runID: run.id, root: store.dataRoot)
    XCTAssertEqual(store.responseFileRoot(for: run)?.path, root.path)
  }

  func testUnrelatedOrRelativeReviewRootsCannotBroadenFileAccess() throws {
    let (root, child, store) = try fixture()
    for path in ["relative", root.path + "-other", child.appendingPathComponent("deeper").path] {
      XCTAssertNil(store.responseFileRoot(for: reviewRun(project: child, root: path)))
    }
    let saved = reviewRun(project: child, root: nil)
    try ReviewSnapshotStorage.save(.init(scope: .uncommitted, diff: "diff",
      repositoryRoot: root.path + "-other"), runID: saved.id, root: store.dataRoot)
    XCTAssertNil(store.responseFileRoot(for: saved))
    try ReviewSnapshotStorage.save(.init(scope: .uncommitted, diff: "repaired diff",
      repositoryRoot: root.path), runID: saved.id, root: store.dataRoot)
    XCTAssertEqual(store.responseFileRoot(for: saved)?.path, root.path)
  }

  func testOrdinaryAndProjectlessRepliesKeepTheirWorkspaceScope() throws {
    let (root, child, store) = try fixture()
    let ordinary = AgentRun(id: UUID().uuidString, kind: "chat", project: child.path,
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["review_repository_root": .string(root.path)]), result: nil)
    XCTAssertEqual(store.responseFileRoot(for: ordinary)?.path, child.path)
    let projectless = AgentRun(id: UUID().uuidString, kind: "chat", project: "",
      status: "succeeded", createdAt: 0, updatedAt: 0,
      request: .object(["workspace": .string(child.path),
        "review_repository_root": .string(root.path)]), result: nil)
    XCTAssertEqual(store.responseFileRoot(for: projectless)?.path, child.path)
    let legacy = reviewRun(project: child, root: nil)
    try ReviewSnapshotStorage.save(.init(scope: .uncommitted, diff: "old local diff"),
      runID: legacy.id, root: store.dataRoot)
    XCTAssertNil(store.responseFileRoot(for: legacy))
  }

  func testSummaryPaneConvertsOnlyFilesInsideProjectAndRechecksSymlinks() throws {
    let (root, child, store) = try fixture()
    let inside = child.appendingPathComponent("inside.swift")
    let outside = root.appendingPathComponent("outside.swift")
    try Data("inside".utf8).write(to: inside)
    try Data("outside".utf8).write(to: outside)
    let run = reviewRun(project: child, root: root.path,
      reply: "[inside](App/inside.swift) [outside](outside.swift)")
    let files = TaskSummaryLinkedFiles.collect([run], rootForRun: { store.responseFileRoot(for: $0) })
    XCTAssertEqual(files.count, 2)
    let internalFile = try XCTUnwrap(files.first { $0.title == "inside.swift" })
    let repositoryFile = try XCTUnwrap(files.first { $0.title == "outside.swift" })
    XCTAssertEqual(internalFile.panePath(in: child), "inside.swift")
    XCTAssertNil(repositoryFile.panePath(in: child))
    store.project = child
    store.workspace.setProject(child)
    store.library.tasks = [.init(id: "task", project: child.path, title: "Review", runIDs: [run.id])]
    store.selection = run.id
    defer { store.workspace.setProject(nil) }
    XCTAssertTrue(store.revealTaskSummaryFile(internalFile))
    XCTAssertEqual(store.activeWorkspaceContentTab, .file("inside.swift", owner: "task"))
    XCTAssertFalse(store.revealTaskSummaryFile(repositoryFile))
    try FileManager.default.removeItem(at: inside)
    try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: outside)
    XCTAssertNil(internalFile.panePath(in: child))
    XCTAssertFalse(store.revealTaskSummaryFile(internalFile))
  }

  func testRepositoryLinksStillRejectEscapeAndPreserveLineNumbers() throws {
    let (root, child, store) = try fixture()
    let run = reviewRun(project: child, root: root.path)
    let base = try XCTUnwrap(store.responseFileRoot(for: run))
    XCTAssertEqual(try MessageLink.target(XCTUnwrap(MessageLink.url("App/source.swift:42")), root: base),
      .file(path: "App/source.swift", line: 42))
    XCTAssertThrowsError(try MessageLink.target(XCTUnwrap(MessageLink.url("../escape.swift")), root: base))
    let web = try XCTUnwrap(URL(string: "https://example.com/review"))
    XCTAssertEqual(try MessageLink.target(web, root: nil), .web(web))
  }

  private func fixture() throws -> (URL, URL, WorkspaceStore) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let child = root.appendingPathComponent("App", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, child, WorkspaceStore(dataRoot: root.appendingPathComponent("Data")))
  }

  private func reviewRun(project: URL, root: String?, reply: String = "[source](App/source.swift)") -> AgentRun {
    var request: [String: JSONValue] = ["conversation_kind": .string("review")]
    if let root { request["review_repository_root"] = .string(root) }
    return .init(id: UUID().uuidString, kind: "chat", project: project.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .object(request), result: .object(["response": .string(reply)]))
  }
}
